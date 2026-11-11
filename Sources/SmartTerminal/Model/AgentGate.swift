import AppKit
import Foundation
import Network
import SmartTerminalCore

/// How agent tools in a Smart Terminal tab reach the app (smart-terminal-mcp): a local
/// endpoint, on 127.0.0.1 only, that answers to a secret.
///
/// `chromium-gate.json` in the app's support folder (readable by you alone) names the
/// endpoint and its token; every shell gets its path as `SMART_TERMINAL_GATE`. The name
/// is from when the gate also handed out browsers (until 0.16.0); it stays so shells
/// that outlive the app (tmux) keep finding it.
///
///     POST /v1/commands        {"tab", "command", "cwd"?, "reason"?, "wait"?}
///       → {"id", "status", ...}  a command typed into a new tab for you to run
///     GET /v1/commands/<id>?wait=<seconds>
@MainActor
final class AgentGate {
    static let shared = AgentGate()

    nonisolated static var infoFile: URL { ShellIntegration.supportDir.appendingPathComponent("chromium-gate.json") }

    /// Finds a tab, opens the proposal's tab... The app model does that.
    weak var model: AppModel?

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let controlToken = AgentGate.newToken()
    private var clients: [ObjectIdentifier: GateClient] = [:]

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Listens and writes the info file.
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

    /// One HTTP request; the reply goes to `respond`.
    fileprivate func handle(_ req: HTTPRequest, respond: @escaping (Data) -> Void) {
        let parts = req.path.split(separator: "?", omittingEmptySubsequences: false)[0].split(separator: "/").map(String.init)
        guard req.bearerToken == controlToken else {
            respond(HTTPResponse.json(401, ["error": "Smart Terminal's gate wants the token in chromium-gate.json"]))
            return
        }
        switch (req.method, parts) {
        case ("POST", ["v1", "commands"]):
            // A command Claude proposes: typed into a new tab for you to run.
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            guard let model, let tabID = model.agentTab(body["tab"] as? String) else {
                respond(HTTPResponse.json(404, ["error": "no such tab"]))
                return
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
                return
            }
            let wait = min(max(Self.query(req.path)["wait"].flatMap(Double.init) ?? 0, 0), 1800)
            model.proposals.wait(p[2], seconds: wait) { respond(HTTPResponse.json(200, ["id": p[2]].merging($0.json) { a, _ in a })) }
        default:
            respond(HTTPResponse.json(404, ["error": "no such endpoint"]))
        }
    }

    private static func query(_ path: String) -> [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        return Dictionary(q.split(separator: "&").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1].removingPercentEncoding ?? kv[1]) : nil
        }, uniquingKeysWith: { a, _ in a })
    }
}

/// A TCP connection to the gate: one HTTP request, one reply.
@MainActor
final class GateClient {
    private let connection: NWConnection
    private unowned let gate: AgentGate
    private var buffer = Data()
    private var answered = false

    init(connection: NWConnection, gate: AgentGate) {
        self.connection = connection
        self.gate = gate
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self.map { $0.gate.ended($0) }
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
                if done || error != nil { self.connection.cancel() } else { self.receive() } // a long poll ends when its client hangs up
            }
        }
    }

    private func received(_ data: Data) {
        guard !answered else { return }
        buffer.append(data)
        guard let (req, _) = HTTPRequest.parse(buffer) else { return }
        answered = true
        buffer = Data()
        gate.handle(req) { [weak self] response in
            self?.connection.send(content: response, completion: .contentProcessed { _ in self?.connection.cancel() })
        }
    }
}
