import AppKit
import CefKit
import Foundation
import Network
import SmartTerminalCore

/// How agent tools get a browser in a Smart Terminal tab: a local endpoint, on
/// 127.0.0.1 only, that answers to a secret.
///
/// `chromium-gate.json` in the app's support folder (readable by you alone) names the
/// endpoint and its control token. With the token, a tool asks for a browser in a
/// tab and gets a DevTools WebSocket address of its own:
///
///     POST /v1/browsers   {"tab": "<SMART_TERMINAL_TAB>", "id": "<the tool's browser id>"}
///       → {"id", "tab", "wsEndpoint"}
///     GET /v1/browsers    → the agent browsers there are
///     DELETE /v1/browsers/<id>
///
/// The WebSocket's path carries a token of its own for that browser. Every
/// connection to it gets a `DevToolsGate`: the agent sees its own tab's pages and
/// nothing else of Chromium.
@MainActor
final class ChromiumGate {
    static let shared = ChromiumGate()

    nonisolated static var infoFile: URL { ShellIntegration.supportDir.appendingPathComponent("chromium-gate.json") }

    /// Finds a tab's window, opens its pane... The app model does that.
    weak var model: AppModel?

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let controlToken = ChromiumGate.newToken()
    private(set) var agents: [String: AgentBrowser] = [:]
    private var clients: [ObjectIdentifier: GateClient] = [:]

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Listens and writes the info file. Chromium itself waits for the first request.
    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .ready = state, let p = self?.listener?.port?.rawValue {
                    self?.port = p
                    self?.writeInfo()
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(at: Self.infoFile)
    }

    private func writeInfo() {
        let info: [String: Any] = ["version": 1, "url": "http://127.0.0.1:\(port)", "token": controlToken,
                                   "pid": ProcessInfo.processInfo.processIdentifier]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) else { return }
        let path = Self.infoFile.path
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        try? data.write(to: Self.infoFile, options: .atomic)
        chmod(path, 0o600)
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        let client = GateClient(connection: conn, gate: self)
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    fileprivate func ended(_ client: GateClient) {
        clients[ObjectIdentifier(client)] = nil
    }

    /// One HTTP request; the reply goes to `respond`. A WebSocket upgrade returns the
    /// agent browser it's for instead.
    fileprivate func handle(_ req: HTTPRequest, respond: @escaping (Data) -> Void) -> AgentBrowser? {
        let parts = req.path.split(separator: "?", omittingEmptySubsequences: false)[0].split(separator: "/").map(String.init)
        if req.isWebSocketUpgrade, parts.count == 3, parts[0] == "devtools", parts[1] == "browser",
           let agent = agents.values.first(where: { $0.token == parts[2] }) {
            return agent
        }
        guard req.bearerToken == controlToken else {
            respond(HTTPResponse.json(401, ["error": "Smart Terminal's browser gate wants the token in chromium-gate.json"]))
            return nil
        }
        switch (req.method, parts) {
        case ("GET", ["v1", "browsers"]):
            respond(HTTPResponse.json(200, ["browsers": agents.values.map(\.summary)]))
        case ("POST", ["v1", "browsers"]):
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            guard let id = body["id"] as? String, !id.isEmpty else {
                respond(HTTPResponse.json(400, ["error": "id is required"]))
                return nil
            }
            let t = body["tmux"] as? [String: Any]
            let tmux = (t?["socket"] as? String).flatMap { s in (t?["session"] as? String).map { (socket: s, session: $0) } }
            Task { respond(await self.ensureAgent(id: id, tab: body["tab"] as? String, tmux: tmux)) }
        case ("POST", ["v1", "commands"]):
            // A command Claude proposes: typed into a new tab for you to run.
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            guard let model, let tabID = model.agentTab(body["tab"] as? String) else {
                respond(HTTPResponse.json(404, ["error": "no such tab"]))
                return nil
            }
            switch model.proposeCommand(body["command"] as? String ?? "", from: tabID,
                                        cwd: body["cwd"] as? String, reason: body["reason"] as? String) {
            case .failure(let e):
                respond(HTTPResponse.json(400, ["error": e.message]))
            case .success(let id):
                let wait = min(max((body["wait"] as? Double) ?? 0, 0), 1800)
                model.proposals.wait(id, seconds: wait) { respond(HTTPResponse.json(200, ["id": id].merging($0.json) { a, _ in a })) }
            }
        case ("GET", let p) where p.count == 3 && p[0] == "v1" && p[1] == "commands":
            guard let model, model.proposals.status(p[2]) != nil else {
                respond(HTTPResponse.json(404, ["error": "no such command"]))
                return nil
            }
            let wait = min(max(Self.query(req.path)["wait"].flatMap(Double.init) ?? 0, 0), 1800)
            model.proposals.wait(p[2], seconds: wait) { respond(HTTPResponse.json(200, ["id": p[2]].merging($0.json) { a, _ in a })) }
        case ("DELETE", let p) where p.count == 3 && p[0] == "v1" && p[1] == "browsers":
            if let agent = agents.removeValue(forKey: p[2]) { agent.close() }
            respond(HTTPResponse.json(200, ["closed": p[2]]))
        default:
            respond(HTTPResponse.json(404, ["error": "no such endpoint"]))
        }
        return nil
    }

    private static func query(_ path: String) -> [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        return Dictionary(q.split(separator: "&").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1].removingPercentEncoding ?? kv[1]) : nil
        }, uniquingKeysWith: { a, _ in a })
    }

    private func ensureAgent(id: String, tab: String?, tmux: (socket: String, session: String)?) async -> Data {
        if let existing = agents[id], existing.isAlive {
            return HTTPResponse.json(200, existing.summary) // same agent tool, reconnecting
        }
        guard let model, let tabID = model.agentTab(tab, tmux: tmux) else {
            return HTTPResponse.json(404, ["error": "no such tab: \(tab ?? "-")"])
        }
        guard ChromiumRuntime.start() else {
            return HTTPResponse.json(503, ["error": "Chromium didn't start: \(ChromiumRuntime.startError ?? "unknown")"])
        }
        let agent = AgentBrowser(id: id, tabID: tabID, port: port)
        guard await agent.open(in: model) else {
            return HTTPResponse.json(503, ["error": "Chromium didn't open the tab's page"])
        }
        agents[id]?.close()
        agents[id] = agent
        return HTTPResponse.json(200, agent.summary)
    }

    /// The agent browser in a tab, if any (the tab closed: its agent goes too).
    func agent(inTab tabID: UUID) -> AgentBrowser? { agents.values.first { $0.tabID == tabID } }

    func tabClosed(_ tabID: UUID) {
        for (id, agent) in agents where agent.tabID == tabID {
            agent.close()
            agents[id] = nil
        }
    }

    // MARK: Chromium → gates

    /// Every message from Chromium: replies and session events go to the gate that owns
    /// them; browser-level events on the app's own session to the target directory.
    func route(_ message: DevToolsMessage) {
        let msg = message.object
        let gates = agents.values.flatMap(\.connections)
        if let session = msg["sessionId"] as? String {
            gates.first { $0.gate.owns(sessionID: session) }?.fromChromium(message)
        } else if let id = msg["id"] as? Int {
            gates.first { $0.gate.owns(replyID: id) }?.fromChromium(message)
        } else if let method = msg["method"] as? String {
            ChromiumTargets.shared.handle(method: method, params: msg["params"] as? [String: Any] ?? [:])
        }
    }

    /// Ids for commands on the shared pipe, apart from the app's own.
    private var nextUpstreamID = 1
    func newUpstreamID() -> Int { defer { nextUpstreamID += 1 }; return nextUpstreamID }
}

/// The browser one agent tool asked for: a tab's pane, an in-memory profile of its
/// own, and the gates of the DevTools connections to it.
@MainActor
final class AgentBrowser {
    let id: String
    let tabID: UUID
    let token = ChromiumGate.newToken()
    let profile = CefProfile.incognito()
    private let port: UInt16
    private(set) var contextID: String?
    private(set) var connections: [GateConnection] = []
    /// The agent's own: it keeps running while another agent's browser has the tab's pane.
    private(set) var browser: BrowserState?
    /// Pages by DevTools target id.
    private var pages: [String: BrowserPage] = [:]

    init(id: String, tabID: UUID, port: UInt16) {
        self.id = id
        self.tabID = tabID
        self.port = port
    }

    var wsEndpoint: String { "ws://127.0.0.1:\(port)/devtools/browser/\(token)" }
    var isAlive: Bool { browser != nil && contextID != nil }
    var summary: [String: Any] {
        ["id": id, "tab": tabID.uuidString, "wsEndpoint": wsEndpoint, "pages": pages.count]
    }

    /// Opens the tab's pane with a first page, which tells the agent's context apart.
    func open(in model: AppModel) async -> Bool {
        let b = model.browsers.openAgent(id: id, in: tabID, profile: profile)
        browser = b
        guard let info = await newPage(url: URL(string: "about:blank")!, select: true) else { return false }
        contextID = info.contextID
        return true
    }

    /// A page in the agent's pane; nil if Chromium never reported it.
    func newPage(url: URL, select: Bool) async -> ChromiumTargets.Info? {
        guard let browser, let page = Optional(browser.addPage(select: select)),
              let engine = page.engine as? ChromiumPage,
              let info = await engine.open(url) else { return nil }
        engine.keepDesktopWidth(targetID: info.targetID)
        pages[info.targetID] = page
        return info
    }

    func closePage(targetID: String) {
        guard let page = pages.removeValue(forKey: targetID) else { return }
        browser?.closePage(page)
    }

    func pageViewport(targetID: String, mobile: Bool?) {
        (pages[targetID]?.engine as? ChromiumPage)?.agentSetViewport(mobile: mobile)
    }

    func activatePage(targetID: String) {
        if let page = pages[targetID] { browser?.select(page) }
    }

    /// A new DevTools client: a browser-level session on the pipe for its gate.
    func connect(_ client: GateClient) async -> GateConnection? {
        guard let contextID else { return nil }
        let session: String? = await withCheckedContinuation { cont in
            DevToolsConnection.shared.send(method: "Target.attachToBrowserTarget") { reply in
                cont.resume(returning: (reply["result"] as? [String: Any])?["sessionId"] as? String)
            }
        }
        guard let session else { return nil }
        let c = GateConnection(agent: self, client: client,
                               gate: DevToolsGate(browserSession: session, contextID: contextID,
                                                  knownTargets: Set(pages.keys),
                                                  allocateID: { ChromiumGate.shared.newUpstreamID() }))
        connections.append(c)
        return c
    }

    func disconnected(_ c: GateConnection) {
        connections.removeAll { $0 === c }
    }

    func close() {
        connections.forEach { $0.client.close() }
        connections = []
        if let browser, let model = ChromiumGate.shared.model {
            let next = ChromiumGate.shared.agents.values.first { $0 !== self && $0.tabID == tabID && $0.browser != nil }
            model.browsers.closeAgent(browser, in: tabID, next: next?.browser)
        }
        browser = nil
    }
}

/// One DevTools client of an agent browser, and its gate.
@MainActor
final class GateConnection {
    /// Weak: the browser can end (closed by you or its tool) while clients are still connected.
    weak var agent: AgentBrowser?
    let client: GateClient
    var gate: DevToolsGate

    init(agent: AgentBrowser, client: GateClient, gate: DevToolsGate) {
        self.agent = agent
        self.client = client
        self.gate = gate
    }

    /// The client is gone (or its browser): undo what it set up in Chromium, whether
    /// or not the browser is still there. A client's auto-attach outlives it otherwise
    /// and holds every new page in Chromium at its start.
    func end() {
        for out in gate.teardown() { if case .toChromium(let d) = out { DevToolsConnection.shared.write(d) } }
        DevToolsConnection.shared.send(method: "Target.detachFromTarget", params: ["sessionId": gate.browserSession])
        agent?.disconnected(self)
    }

    func fromClient(_ data: Data) {
        perform(gate.fromClient(data, newID: ChromiumGate.shared.newUpstreamID))
    }

    func fromChromium(_ message: DevToolsMessage) {
        perform(gate.fromChromium(message.data, parsed: message.object))
    }

    private func perform(_ outputs: [DevToolsGate.Output]) {
        for out in outputs {
            switch out {
            case .toClient(let d): client.send(d)
            case .toChromium(let d): DevToolsConnection.shared.write(d)
            case .activatePage(let t): agent?.activatePage(targetID: t)
            case .pageViewport(let t, let mobile): agent?.pageViewport(targetID: t, mobile: mobile)
            case .closePage(let rid, let t):
                agent?.closePage(targetID: t)
                perform(gate.pageClosed(requestID: rid))
            case .createPage(let rid, let url, let background):
                Task {
                    let info = await agent?.newPage(url: URL(string: url) ?? URL(string: "about:blank")!, select: !background)
                    if let info {
                        perform(gate.pageCreated(requestID: rid, targetID: info.targetID))
                    } else {
                        let err = ["id": rid, "error": ["code": -32000, "message": "Smart Terminal couldn't open the page"]] as [String: Any]
                        client.send((try? JSONSerialization.data(withJSONObject: err)) ?? Data())
                    }
                }
            }
        }
    }
}

/// A TCP connection to the gate: one HTTP request, or a WebSocket after an upgrade.
@MainActor
final class GateClient {
    private let connection: NWConnection
    private unowned let gate: ChromiumGate
    private var buffer = Data()
    private var codec: WebSocketCodec?
    private var session: GateConnection?
    private var early: [Data] = [] // messages that arrived before the gate's session did

    init(connection: NWConnection, gate: ChromiumGate) {
        self.connection = connection
        self.gate = gate
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finished()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.received(data) }
                if done || error != nil { self.close() } else { self.receive() }
            }
        }
    }

    private func received(_ data: Data) {
        if codec != nil {
            do {
                for message in try codec!.receive(data) {
                    switch message {
                    case .text(let d), .binary(let d):
                        if let session { session.fromClient(d) } else { early.append(d) }
                    case .ping(let d): connection.send(content: WebSocketCodec.frame(d, opcode: 0xA), completion: .idempotent)
                    case .close: close()
                    }
                }
            } catch { close() }
            return
        }
        buffer.append(data)
        guard let (req, used) = HTTPRequest.parse(buffer) else { return }
        let rest = buffer.dropFirst(used)
        buffer = Data()
        let agent = gate.handle(req) { [weak self] response in
            self?.connection.send(content: response, completion: .contentProcessed { _ in self?.connection.cancel() })
        }
        guard let agent, let key = req.headers["sec-websocket-key"] else { return }
        codec = WebSocketCodec()
        connection.send(content: HTTPResponse.upgrade(key: key), completion: .idempotent)
        if !rest.isEmpty { received(Data(rest)) }
        Task {
            guard let s = await agent.connect(self) else { self.close(); return }
            self.session = s
            self.early.forEach(s.fromClient)
            self.early = []
        }
    }

    func send(_ message: Data) {
        connection.send(content: WebSocketCodec.frame(message), completion: .idempotent)
    }

    func close() {
        connection.cancel()
    }

    private func finished() {
        session?.end()
        session = nil
        gate.ended(self)
    }
}
