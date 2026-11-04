import Foundation

/// What one agent may do with the app's Chromium, as a filter on the DevTools
/// protocol between that agent's client (chrome-devtools-mcp) and Chromium.
///
/// Every agent shares one Chromium, so the gate is what keeps them apart and away
/// from your own pages:
/// - It speaks to Chromium on a browser-level session of its own (`browserSession`),
///   so one agent's `setDiscoverTargets` or `setAutoAttach` never touches another's.
/// - It only shows targets in its agent's browser context (an in-memory profile of
///   its own) and only relays sessions it attached. Your pages live in the default
///   context, which an agent never sees.
/// - Browser-wide commands are allowlisted; the ones that take a context (cookies,
///   permissions, downloads) are pinned to the agent's.
/// - Opening a page is the app's job (`createPage`): Chromium on its own would open a
///   Chrome window instead of a page in the tab's pane.
///
/// Pure logic: the app feeds messages in and carries out what comes back.
public struct DevToolsGate {
    public enum Output: Equatable {
        /// Deliver to the agent's client.
        case toClient(Data)
        /// Send to Chromium.
        case toChromium(Data)
        /// Open a page in the agent's tab, then call `pageCreated`.
        case createPage(requestID: Int, url: String, background: Bool)
        /// Close one of the agent's pages, then call `pageClosed`.
        case closePage(requestID: Int, targetID: String)
        /// Show one of the agent's pages in the tab's pane.
        case activatePage(targetID: String)
    }

    /// The gate's browser-level session on the pipe.
    public let browserSession: String
    /// The agent's browser context. Nothing is visible before it's known.
    public let contextID: String
    public private(set) var targets: Set<String> = []
    private var sessions: Set<String> = []
    private var pending: [Int: Pending] = [:]
    /// Targets Chromium announced as "other": a page it creates starts out that way and
    /// turns into a "page" a moment later. Clients decide a target's kind when it
    /// appears (puppeteer would never see a page), so the gate holds what it hears of
    /// one until it has its real type. Values: the messages held, in order.
    private var held: [String: [Data]] = [:]
    private var heldSessions: [String: String] = [:] // session → target

    private struct Pending {
        let clientID: Int
        let method: String
        /// The client's session, nil for browser-level commands.
        let sessionID: String?
        var kind: Kind = .client

        enum Kind { case client, utilityAttach, cookies }
    }

    /// Cookies are per browser context, but Chromium's DevTools only knows the contexts
    /// it made itself, not the app's in-memory profiles: `Storage.*Cookies` with the
    /// agent's context fails. The gate answers them on a page session of its own, on one
    /// of the agent's pages, with the `Network` equivalents (which act on that page's
    /// context). Never shown to the client.
    private var utilitySession: String?
    private var utilityTarget: String?
    private var cookieQueue: [(clientID: Int, method: String, params: [String: Any])] = []
    private var attachingUtility = false

    static let cookieMethods: [String: String] = [
        "Storage.getCookies": "Network.getAllCookies",
        "Storage.setCookies": "Network.setCookies",
        "Storage.clearCookies": "Network.clearBrowserCookies",
    ]

    /// `knownTargets`: the agent's pages so far (the app knows them; the client may
    /// not have asked yet).
    /// `allocateID`: ids unique on the shared pipe, for commands the gate sends when
    /// answering Chromium (the same allocator `fromClient` gets).
    public init(browserSession: String, contextID: String, knownTargets: Set<String> = [],
                allocateID: @escaping () -> Int) {
        self.browserSession = browserSession
        self.contextID = contextID
        targets = knownTargets
        self.allocateID = allocateID
    }

    private let allocateID: () -> Int

    /// Whether a message from Chromium belongs to this gate: an answer it waits for,
    /// or something on one of its sessions.
    public func owns(replyID: Int) -> Bool { pending[replyID] != nil }
    public func owns(sessionID: String) -> Bool {
        sessionID == browserSession || sessions.contains(sessionID) || sessionID == utilitySession
    }

    /// Methods without a session the client may call. Values: whether the method
    /// takes the agent's context (`browserContextId` is set to it).
    static let browserMethods: [String: Bool] = [
        "Target.setDiscoverTargets": false,
        "Target.setAutoAttach": false,
        "Target.getTargets": false,
        "Target.getTargetInfo": false,
        "Target.attachToTarget": false,
        "Target.detachFromTarget": false,
        "Browser.getVersion": false,
        "Browser.getWindowForTarget": false,
        "Browser.getWindowBounds": false,
        "Browser.setDownloadBehavior": true,
        "Browser.cancelDownload": true,
        "Browser.grantPermissions": true,
        "Browser.resetPermissions": true,
        "Browser.setPermission": true,
        "SystemInfo.getInfo": false,
    ]

    /// Never on a page session either: they reach past the page, to other targets or contexts.
    static let browserOnly: Set<String> = [
        "Target.createTarget", "Target.closeTarget", "Target.createBrowserContext",
        "Target.disposeBrowserContext", "Target.getBrowserContexts", "Target.attachToBrowserTarget",
        "Target.exposeDevToolsProtocol", "Target.setRemoteLocations", "Target.getTargets",
        "Target.setDiscoverTargets", "Target.activateTarget", "Browser.close", "Browser.crash",
        "Storage.getCookies", "Storage.setCookies", "Storage.clearCookies",
    ]

    // MARK: Client → Chromium

    /// A message from the client. `newID` hands out ids unique on the shared pipe.
    public mutating func fromClient(_ data: Data, newID: () -> Int) -> [Output] {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = msg["id"] as? Int, let method = msg["method"] as? String else { return [] }
        var params = msg["params"] as? [String: Any] ?? [:]
        let session = msg["sessionId"] as? String

        // Whatever the level: a target named must be the agent's, and a context named is
        // the agent's whatever the client wrote.
        if method.hasPrefix("Target."), let target = params["targetId"] as? String, !targets.contains(target) {
            return [error(id, session, "No target with given id found")]
        }
        if params["browserContextId"] != nil { params["browserContextId"] = contextID }

        if let session {
            guard sessions.contains(session) else { return [error(id, session, "No such session")] }
            guard !Self.browserOnly.contains(method) else {
                return [error(id, session, "\(method) isn't available through Smart Terminal's browser gate", code: -32601)]
            }
            return [forward(id: id, method: method, params: params, sessionID: session, as: session, newID: newID)]
        }

        switch method {
        case "Target.createTarget":
            return [.createPage(requestID: id, url: params["url"] as? String ?? "about:blank",
                                background: params["background"] as? Bool ?? false)]
        case "Target.closeTarget":
            return [.closePage(requestID: id, targetID: params["targetId"] as? String ?? "")]
        case "Target.activateTarget":
            return [.activatePage(targetID: params["targetId"] as? String ?? ""), result(id, nil, [:])]
        case "Target.getBrowserContexts":
            // The agent's context is its default: puppeteer files pages in unknown contexts there.
            return [result(id, nil, ["browserContextIds": []])]
        case "Browser.close", "Browser.setWindowBounds", "Browser.crash", "Browser.crashGpuProcess":
            // The browser and its window are the app's.
            return [result(id, nil, [:])]
        case "Target.detachFromTarget":
            if let s = params["sessionId"] as? String, !sessions.contains(s) {
                return [error(id, nil, "No session with given id")]
            }
        default:
            break
        }
        if Self.cookieMethods[method] != nil {
            return cookies(clientID: id, method: method, params: params, newID: newID)
        }
        guard let takesContext = Self.browserMethods[method] else {
            return [error(id, nil, "\(method) isn't available through Smart Terminal's browser gate", code: -32601)]
        }
        if takesContext { params["browserContextId"] = contextID }
        return [forward(id: id, method: method, params: params, sessionID: nil, as: browserSession, newID: newID)]
    }

    /// The app opened the page asked for with `createPage`.
    public mutating func pageCreated(requestID: Int, targetID: String) -> [Output] {
        targets.insert(targetID)
        return [result(requestID, nil, ["targetId": targetID])]
    }

    public mutating func pageClosed(requestID: Int) -> [Output] {
        [result(requestID, nil, ["success": true])]
    }

    // MARK: Chromium → client

    /// A message from Chromium that `owns` this gate.
    public mutating func fromChromium(_ data: Data) -> [Output] {
        guard var msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let id = msg["id"] as? Int {
            guard let p = pending.removeValue(forKey: id) else { return [] }
            switch p.kind {
            case .utilityAttach:
                attachingUtility = false
                guard let s = (msg["result"] as? [String: Any])?["sessionId"] as? String else {
                    let waiting = cookieQueue
                    cookieQueue = []
                    return waiting.map { error($0.clientID, nil, "No page to read cookies through") }
                }
                utilitySession = s
                return flushCookies(using: allocateID)
            case .cookies:
                var reply: [String: Any] = ["id": p.clientID]
                if let e = msg["error"] { reply["error"] = e } else {
                    let r = msg["result"] as? [String: Any] ?? [:]
                    reply["result"] = p.method == "Storage.getCookies" ? ["cookies": r["cookies"] ?? []] : [:]
                }
                return [encoded(reply)]
            case .client:
                break
            }
            msg["id"] = p.clientID
            if let s = p.sessionID { msg["sessionId"] = s } else { msg.removeValue(forKey: "sessionId") }
            if var result = msg["result"] as? [String: Any] {
                switch p.method {
                case "Target.getTargets":
                    let infos = (result["targetInfos"] as? [[String: Any]] ?? []).filter(isOurs)
                    infos.compactMap { $0["targetId"] as? String }.forEach { targets.insert($0) }
                    result["targetInfos"] = infos
                case "Target.attachToTarget":
                    if let s = result["sessionId"] as? String { sessions.insert(s) }
                default: break
                }
                msg["result"] = result
            }
            return [encoded(msg)]
        }

        guard let method = msg["method"] as? String, let session = msg["sessionId"] as? String else { return [] }
        let params = msg["params"] as? [String: Any] ?? [:]
        if session == utilitySession { return [] } // the gate's own; nothing for the client
        if session != browserSession {
            // An event on one of the agent's sessions; its subsessions are the agent's too.
            guard sessions.contains(session) else { return [] }
            if let t = heldSessions[session] { held[t, default: []].append(data); return [] }
            if method == "Target.attachedToTarget", let s = params["sessionId"] as? String { sessions.insert(s) }
            if method == "Target.detachedFromTarget", let s = params["sessionId"] as? String { sessions.remove(s) }
            return [.toClient(data)]
        }

        // Browser-level, on the gate's own session: shown as browser-level to the client.
        msg.removeValue(forKey: "sessionId")
        let info = params["targetInfo"] as? [String: Any]
        if let info, isOurs(info), let t = info["targetId"] as? String {
            let isOther = info["type"] as? String == "other"
            switch method {
            case "Target.targetCreated" where isOther:
                held[t] = [encodedData(msg)]
                return []
            case "Target.attachedToTarget" where isOther || held[t] != nil:
                if let s = params["sessionId"] as? String { sessions.insert(s); heldSessions[s] = t }
                held[t, default: []].append(encodedData(msg))
                return []
            case "Target.targetInfoChanged" where held[t] != nil:
                if isOther { return [] }
                return release(t, as: info)
            default:
                break
            }
        }
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard let info, isOurs(info), let t = info["targetId"] as? String else { return [] }
            targets.insert(t)
        case "Target.targetDestroyed", "Target.targetCrashed":
            guard let t = params["targetId"] as? String, targets.contains(t) else { return [] }
            if t == utilityTarget { utilitySession = nil; utilityTarget = nil }
            if method == "Target.targetDestroyed" { targets.remove(t) }
        case "Target.attachedToTarget":
            guard let s = params["sessionId"] as? String else { return [] }
            guard let info, isOurs(info) else {
                // Auto-attach caught someone else's target: let it run on and let go.
                return [command("Runtime.runIfWaitingForDebugger", [:], session: s, newID: nil),
                        command("Target.detachFromTarget", ["sessionId": s], session: browserSession, newID: nil)]
            }
            sessions.insert(s)
            if let t = info["targetId"] as? String { targets.insert(t) }
        case "Target.detachedFromTarget":
            guard let s = params["sessionId"] as? String, sessions.remove(s) != nil else { return [] }
        default:
            return [] // downloads and the like carry no context to check
        }
        return [encoded(msg)]
    }

    // MARK: Leaving

    /// The client went away. What it set up in Chromium outlives its connection: a
    /// browser-level auto-attach with waitForDebuggerOnStart would hold every new page
    /// of the agent's at its start, for a debugger that never comes; request
    /// interception on a page would hold its requests. So: no more auto-attach or
    /// discovery, every page let run, every session dropped. The app then detaches
    /// `browserSession` itself.
    public mutating func teardown() -> [Output] {
        var out = [command("Target.setAutoAttach", ["autoAttach": false, "waitForDebuggerOnStart": false],
                           session: browserSession, newID: nil),
                   command("Target.setDiscoverTargets", ["discover": false], session: browserSession, newID: nil)]
        let all = sessions.union(heldSessions.keys).union([utilitySession].compactMap { $0 })
        for s in all.sorted() {
            out.append(command("Runtime.runIfWaitingForDebugger", [:], session: s, newID: nil))
            out.append(command("Target.detachFromTarget", ["sessionId": s], session: browserSession, newID: nil))
        }
        sessions = []
        heldSessions = [:]
        held = [:]
        utilitySession = nil
        pending = [:]
        return out
    }

    // MARK: Cookies

    private mutating func cookies(clientID: Int, method: String, params: [String: Any], newID: () -> Int) -> [Output] {
        var p = params
        p.removeValue(forKey: "browserContextId")
        cookieQueue.append((clientID, method, p))
        if utilitySession != nil { return flushCookies(using: newID) }
        guard !attachingUtility else { return [] }
        guard let target = targets.sorted().first else {
            cookieQueue.removeLast()
            return [error(clientID, nil, "No page to read cookies through yet")]
        }
        attachingUtility = true
        utilityTarget = target
        let upstream = newID()
        pending[upstream] = Pending(clientID: -1, method: "Target.attachToTarget", sessionID: nil, kind: .utilityAttach)
        return [command("Target.attachToTarget", ["targetId": target, "flatten": true], session: browserSession, newID: upstream)]
    }

    /// Sends the queued cookie commands on the utility session.
    private mutating func flushCookies(using newID: () -> Int) -> [Output] {
        guard let session = utilitySession else { return [] }
        let queue = cookieQueue
        cookieQueue = []
        return queue.map { item in
            let upstream = newID()
            pending[upstream] = Pending(clientID: item.clientID, method: item.method, sessionID: nil, kind: .cookies)
            return command(Self.cookieMethods[item.method]!, item.params, session: session, newID: upstream)
        }
    }


    /// A held target got its real type: what was held goes out with the real info.
    private mutating func release(_ target: String, as info: [String: Any]) -> [Output] {
        targets.insert(target)
        heldSessions = heldSessions.filter { $0.value != target }
        return (held.removeValue(forKey: target) ?? []).map { data in
            guard var m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var p = m["params"] as? [String: Any], p["targetInfo"] != nil else { return .toClient(data) }
            p["targetInfo"] = info
            m["params"] = p
            return encoded(m)
        }
    }

    private func encodedData(_ msg: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
    }

    private func isOurs(_ info: [String: Any]) -> Bool {
        info["browserContextId"] as? String == contextID
    }

    // MARK: Building messages

    private mutating func forward(id: Int, method: String, params: [String: Any], sessionID: String?,
                                  as upstreamSession: String, newID: () -> Int) -> Output {
        let upstream = newID()
        pending[upstream] = Pending(clientID: id, method: method, sessionID: sessionID)
        return command(method, params, session: upstreamSession, newID: upstream)
    }

    /// A command to Chromium. Without an id (`newID: nil`) the reply is nobody's and is dropped.
    private func command(_ method: String, _ params: [String: Any], session: String, newID: Int?) -> Output {
        var msg: [String: Any] = ["method": method, "params": params, "sessionId": session]
        msg["id"] = newID ?? Self.unansweredID
        return .toChromium((try? JSONSerialization.data(withJSONObject: msg)) ?? Data())
    }

    /// Commands the gate sends for its own sake; nobody waits for their replies.
    public static let unansweredID = 0

    private func result(_ id: Int, _ session: String?, _ result: [String: Any]) -> Output {
        var msg: [String: Any] = ["id": id, "result": result]
        if let session { msg["sessionId"] = session }
        return encoded(msg)
    }

    private func error(_ id: Int, _ session: String?, _ text: String, code: Int = -32000) -> Output {
        var msg: [String: Any] = ["id": id, "error": ["code": code, "message": text]]
        if let session { msg["sessionId"] = session }
        return encoded(msg)
    }

    private func encoded(_ msg: [String: Any]) -> Output {
        .toClient((try? JSONSerialization.data(withJSONObject: msg)) ?? Data())
    }
}
