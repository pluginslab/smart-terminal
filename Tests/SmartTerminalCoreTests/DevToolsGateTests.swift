import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct DevToolsGateTests {
    let ours = "CTX-AGENT"
    let yours = "CTX-DEFAULT"

    func gate() -> DevToolsGate {
        var n = 900
        return DevToolsGate(browserSession: "BROWSER", contextID: ours, allocateID: { n += 1; return n })
    }

    func json(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
    func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    /// Ids handed out on the pipe, from 500 up.
    final class IDs { var next = 500; func take() -> Int { defer { next += 1 }; return next } }

    func toChromium(_ out: [DevToolsGate.Output]) -> [[String: Any]] {
        out.compactMap { if case .toChromium(let d) = $0 { return obj(d) } else { return nil } }
    }
    func toClient(_ out: [DevToolsGate.Output]) -> [[String: Any]] {
        out.compactMap { if case .toClient(let d) = $0 { return obj(d) } else { return nil } }
    }
    func info(_ id: String, _ ctx: String, type: String = "page") -> [String: Any] {
        ["targetId": id, "browserContextId": ctx, "type": type, "url": "https://x.test/"]
    }

    @Test func browserCommandsRunOnTheGatesOwnSession() {
        var g = gate(); let ids = IDs()
        let sent = toChromium(g.fromClient(json(["id": 1, "method": "Target.setDiscoverTargets", "params": ["discover": true]]), newID: ids.take))
        #expect(sent.count == 1)
        #expect(sent[0]["sessionId"] as? String == "BROWSER")
        #expect(sent[0]["id"] as? Int == 500)
        // The reply comes back with the client's id, and no session (it asked browser-level).
        #expect(g.owns(replyID: 500))
        let back = toClient(g.fromChromium(json(["id": 500, "sessionId": "BROWSER", "result": [:]])))
        #expect(back[0]["id"] as? Int == 1)
        #expect(back[0]["sessionId"] == nil)
        #expect(!g.owns(replyID: 500))
    }

    @Test func onlyTheAgentsTargetsAreListedOrAnnounced() {
        var g = gate(); let ids = IDs()
        _ = g.fromClient(json(["id": 2, "method": "Target.getTargets"]), newID: ids.take)
        let list = toClient(g.fromChromium(json(["id": 500, "sessionId": "BROWSER",
                                                 "result": ["targetInfos": [info("A", ours), info("Y", yours)]]])))
        let infos = (list[0]["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? []
        #expect(infos.map { $0["targetId"] as? String } == ["A"])

        let created = { (t: [String: Any]) in
            self.json(["method": "Target.targetCreated", "sessionId": "BROWSER", "params": ["targetInfo": t]])
        }
        #expect(toClient(g.fromChromium(created(info("Y2", yours)))).isEmpty)
        let shown = toClient(g.fromChromium(created(info("B", ours))))
        #expect(shown.count == 1 && shown[0]["sessionId"] == nil)
        #expect(g.targets == ["A", "B"])
        // Destroyed: only the agent's own are reported.
        #expect(toClient(g.fromChromium(json(["method": "Target.targetDestroyed", "sessionId": "BROWSER", "params": ["targetId": "Y"]]))).isEmpty)
        #expect(toClient(g.fromChromium(json(["method": "Target.targetDestroyed", "sessionId": "BROWSER", "params": ["targetId": "B"]]))).count == 1)
        #expect(g.targets == ["A"])
    }

    @Test func attachingToSomeoneElsesTargetIsRefused() {
        var g = gate(); let ids = IDs()
        let out = toClient(g.fromClient(json(["id": 3, "method": "Target.attachToTarget", "params": ["targetId": "Y", "flatten": true]]), newID: ids.take))
        #expect((out[0]["error"] as? [String: Any]) != nil)
        // A page session can't either.
        _ = g.pageCreated(requestID: 9, targetID: "A")
        _ = g.fromClient(json(["id": 4, "method": "Target.attachToTarget", "params": ["targetId": "A", "flatten": true]]), newID: ids.take)
        _ = g.fromChromium(json(["id": 500, "sessionId": "BROWSER", "result": ["sessionId": "S-A"]]))
        #expect(g.owns(sessionID: "S-A"))
        let viaPage = toClient(g.fromClient(json(["id": 5, "sessionId": "S-A", "method": "Target.attachToTarget", "params": ["targetId": "Y"]]), newID: ids.take))
        #expect((viaPage[0]["error"] as? [String: Any]) != nil)
    }

    @Test func autoAttachedForeignTargetsAreLetGo() {
        var g = gate()
        let out = g.fromChromium(json(["method": "Target.attachedToTarget", "sessionId": "BROWSER",
                                       "params": ["sessionId": "S-Y", "targetInfo": info("Y", yours), "waitingForDebugger": true]]))
        #expect(toClient(out).isEmpty)
        let sent = toChromium(out)
        #expect(sent.map { $0["method"] as? String } == ["Runtime.runIfWaitingForDebugger", "Target.detachFromTarget"])
        #expect(sent[0]["sessionId"] as? String == "S-Y")
        #expect(!g.owns(sessionID: "S-Y"))
        // The agent's own are kept, with their subsessions.
        _ = g.fromChromium(json(["method": "Target.attachedToTarget", "sessionId": "BROWSER",
                                 "params": ["sessionId": "S-A", "targetInfo": info("A", ours)]]))
        _ = g.fromChromium(json(["method": "Target.attachedToTarget", "sessionId": "S-A",
                                 "params": ["sessionId": "S-A-frame", "targetInfo": info("F", ours, type: "iframe")]]))
        #expect(g.owns(sessionID: "S-A") && g.owns(sessionID: "S-A-frame"))
        #expect(toClient(g.fromChromium(json(["method": "Page.loadEventFired", "sessionId": "S-A-frame", "params": [:]]))).count == 1)
        #expect(toClient(g.fromChromium(json(["method": "Page.loadEventFired", "sessionId": "S-OTHER", "params": [:]]))).isEmpty)
    }

    @Test func cookiesGoThroughAPageOfTheAgents() {
        var g = DevToolsGate(browserSession: "BROWSER", contextID: ours, knownTargets: ["A"], allocateID: { 777 })
        let ids = IDs()
        // First a page session on the agent's page, the client's call waits for it.
        let attach = toChromium(g.fromClient(json(["id": 6, "method": "Storage.setCookies",
                                                   "params": ["browserContextId": yours, "cookies": [["name": "a"]]]]), newID: ids.take))
        #expect(attach.map { $0["method"] as? String } == ["Target.attachToTarget"])
        #expect((attach[0]["params"] as? [String: Any])?["targetId"] as? String == "A")
        let sent = toChromium(g.fromChromium(json(["id": 500, "sessionId": "BROWSER", "result": ["sessionId": "UTIL"]])))
        #expect(sent.map { $0["method"] as? String } == ["Network.setCookies"])
        #expect(sent[0]["sessionId"] as? String == "UTIL")
        #expect((sent[0]["params"] as? [String: Any])?["browserContextId"] == nil)
        // The answer goes back as the Storage reply; the utility session stays hidden.
        let back = toClient(g.fromChromium(json(["id": 777, "sessionId": "UTIL", "result": [:]])))
        #expect(back[0]["id"] as? Int == 6 && back[0]["sessionId"] == nil)
        #expect(toClient(g.fromChromium(json(["method": "Network.dataReceived", "sessionId": "UTIL", "params": [:]]))).isEmpty)
        // Later calls use the session straight away.
        let get = toChromium(g.fromClient(json(["id": 7, "method": "Storage.getCookies"]), newID: ids.take))
        #expect(get.map { $0["method"] as? String } == ["Network.getAllCookies"])
        let cookies = toClient(g.fromChromium(json(["id": 501, "sessionId": "UTIL", "result": ["cookies": [["name": "a"]]]])))
        #expect(((cookies[0]["result"] as? [String: Any])?["cookies"] as? [[String: Any]])?.count == 1)
    }

    @Test func cookiesMoveToAnotherPageWhenTheirsCloses() {
        var g = DevToolsGate(browserSession: "BROWSER", contextID: ours, knownTargets: ["A", "B"], allocateID: { 777 })
        let ids = IDs()
        _ = g.fromClient(json(["id": 6, "method": "Storage.getCookies"]), newID: ids.take)
        _ = g.fromChromium(json(["id": 500, "sessionId": "BROWSER", "result": ["sessionId": "UTIL"]]))
        _ = g.fromChromium(json(["id": 777, "sessionId": "UTIL", "result": ["cookies": []]]))
        // The agent closes the page the cookie session runs on (fleet's restart closes about:blank).
        _ = g.fromClient(json(["id": 8, "method": "Target.closeTarget", "params": ["targetId": "A"]]), newID: ids.take)
        let attach = toChromium(g.fromClient(json(["id": 9, "method": "Storage.getCookies"]), newID: ids.take))
        #expect(attach.map { $0["method"] as? String } == ["Target.attachToTarget"])
        #expect((attach[0]["params"] as? [String: Any])?["targetId"] as? String == "B")
    }

    @Test func aFailedAttachTriesTheNextPage() {
        var g = DevToolsGate(browserSession: "BROWSER", contextID: ours, knownTargets: ["A", "B"], allocateID: { 777 })
        let ids = IDs()
        _ = g.fromClient(json(["id": 6, "method": "Storage.getCookies"]), newID: ids.take)
        // A's gone without the gate hearing of it.
        let retry = toChromium(g.fromChromium(json(["id": 500, "sessionId": "BROWSER", "error": ["message": "No target with given id found"]])))
        #expect(retry.map { $0["method"] as? String } == ["Target.attachToTarget"])
        #expect((retry[0]["params"] as? [String: Any])?["targetId"] as? String == "B")
    }

    @Test func permissionsArePinnedToTheAgentsContext() {
        var g = gate(); let ids = IDs()
        let grant = toChromium(g.fromClient(json(["id": 7, "method": "Browser.grantPermissions", "params": ["permissions": ["geolocation"]]]), newID: ids.take))
        #expect((grant[0]["params"] as? [String: Any])?["browserContextId"] as? String == ours)
    }

    @Test func unlistedOrDangerousCommandsAreRefused() {
        var g = gate(); let ids = IDs()
        for method in ["Target.createBrowserContext", "Target.attachToBrowserTarget", "Tracing.start", "Target.exposeDevToolsProtocol"] {
            let out = g.fromClient(json(["id": 8, "method": method, "params": [:]]), newID: ids.take)
            #expect(toChromium(out).isEmpty, "\(method) reached Chromium")
            #expect((toClient(out).first?["error"] as? [String: Any]) != nil)
        }
        // Closing the browser does nothing; it's the app's.
        let close = g.fromClient(json(["id": 9, "method": "Browser.close"]), newID: ids.take)
        #expect(toChromium(close).isEmpty && toClient(close).first?["result"] != nil)
        // Unknown sessions are refused.
        let stray = g.fromClient(json(["id": 10, "sessionId": "S-Y", "method": "Runtime.evaluate", "params": ["expression": "1"]]), newID: ids.take)
        #expect(toChromium(stray).isEmpty)
    }

    @Test func newPagesAreTheAppsToOpen() {
        var g = gate(); let ids = IDs()
        let out = g.fromClient(json(["id": 11, "method": "Target.createTarget", "params": ["url": "https://a.test/", "background": true]]), newID: ids.take)
        #expect(out == [.createPage(requestID: 11, url: "https://a.test/", background: true)])
        let reply = toClient(g.pageCreated(requestID: 11, targetID: "N"))
        #expect((reply[0]["result"] as? [String: Any])?["targetId"] as? String == "N")
        #expect(g.targets.contains("N"))
        #expect(g.fromClient(json(["id": 12, "method": "Target.closeTarget", "params": ["targetId": "N"]]), newID: ids.take)
                == [.closePage(requestID: 12, targetID: "N")])
        let contexts = toClient(g.fromClient(json(["id": 13, "method": "Target.getBrowserContexts"]), newID: ids.take))
        #expect((contexts[0]["result"] as? [String: Any])?["browserContextIds"] as? [String] == [])
    }

    @Test func aNewPageIsHeldUntilItIsAPage() {
        var g = gate()
        let other = info("N", ours, type: "other")
        #expect(toClient(g.fromChromium(json(["method": "Target.targetCreated", "sessionId": "BROWSER", "params": ["targetInfo": other]]))).isEmpty)
        #expect(toClient(g.fromChromium(json(["method": "Target.attachedToTarget", "sessionId": "BROWSER",
                                              "params": ["sessionId": "S-N", "targetInfo": other, "waitingForDebugger": true]]))).isEmpty)
        #expect(toClient(g.fromChromium(json(["method": "Runtime.executionContextCreated", "sessionId": "S-N", "params": [:]]))).isEmpty)
        let released = toClient(g.fromChromium(json(["method": "Target.targetInfoChanged", "sessionId": "BROWSER",
                                                     "params": ["targetInfo": info("N", ours)]])))
        #expect(released.map { $0["method"] as? String } == ["Target.targetCreated", "Target.attachedToTarget", "Runtime.executionContextCreated"])
        let types = released.prefix(2).map { (($0["params"] as? [String: Any])?["targetInfo"] as? [String: Any])?["type"] as? String }
        #expect(types == ["page", "page"])
        // From then on, its session's events flow straight through.
        #expect(toClient(g.fromChromium(json(["method": "Page.loadEventFired", "sessionId": "S-N", "params": [:]]))).count == 1)
        #expect(g.targets.contains("N"))
    }

    @Test func leavingUndoesWhatTheClientSetUp() {
        var g = gate()
        _ = g.fromChromium(json(["method": "Target.attachedToTarget", "sessionId": "BROWSER",
                                 "params": ["sessionId": "S-A", "targetInfo": info("A", ours), "waitingForDebugger": true]]))
        let out = toChromium(g.teardown())
        #expect(out.map { $0["method"] as? String } == ["Target.setAutoAttach", "Target.setDiscoverTargets",
                                                        "Runtime.runIfWaitingForDebugger", "Target.detachFromTarget"])
        #expect(out.prefix(2).allSatisfy { $0["sessionId"] as? String == "BROWSER" })
        #expect(out[2]["sessionId"] as? String == "S-A")
        #expect(!g.owns(sessionID: "S-A"))
    }

    @Test func viewportOverridesReachTheApp() {
        var g = DevToolsGate(browserSession: "BROWSER", contextID: ours, knownTargets: ["P"], allocateID: { 0 })
        let ids = IDs()
        // Attached by the client (puppeteer attaches pages with auto-attach, also covered).
        _ = g.fromClient(json(["id": 1, "method": "Target.attachToTarget", "params": ["targetId": "P", "flatten": true]]), newID: ids.take)
        _ = g.fromChromium(json(["id": 500, "sessionId": "BROWSER", "result": ["sessionId": "S1"]]))
        _ = g.fromChromium(json(["method": "Target.attachedToTarget", "sessionId": "BROWSER",
                                 "params": ["sessionId": "S2", "targetInfo": info("Q", ours), "waitingForDebugger": false]]))

        let set = g.fromClient(json(["id": 2, "sessionId": "S1", "method": "Emulation.setDeviceMetricsOverride",
                                     "params": ["width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": true]]), newID: ids.take)
        // The app hears first (its zoom goes before the metrics land), then Chromium.
        #expect(set.first == .pageViewport(targetID: "P", mobile: true))
        #expect(toChromium(set).first?["method"] as? String == "Emulation.setDeviceMetricsOverride")
        let desktop = g.fromClient(json(["id": 3, "sessionId": "S2", "method": "Emulation.setDeviceMetricsOverride",
                                         "params": ["width": 1920, "height": 1080, "deviceScaleFactor": 1, "mobile": false]]), newID: ids.take)
        #expect(desktop.first == .pageViewport(targetID: "Q", mobile: false))
        let clear = g.fromClient(json(["id": 4, "sessionId": "S2", "method": "Emulation.clearDeviceMetricsOverride"]), newID: ids.take)
        #expect(clear.first == .pageViewport(targetID: "Q", mobile: nil))
        // Other commands don't.
        let other = g.fromClient(json(["id": 5, "sessionId": "S1", "method": "Runtime.evaluate", "params": ["expression": "1"]]), newID: ids.take)
        #expect(!other.contains { if case .pageViewport = $0 { true } else { false } })
        // Leaving: Chromium drops the client's overrides, and the pane goes back to desktop.
        let left = g.teardown()
        #expect(left.contains(.pageViewport(targetID: "P", mobile: nil)))
        #expect(!left.contains(.pageViewport(targetID: "Q", mobile: nil)))
    }
}
