import AppKit
import CCef
import CCefAppKit
import CefKit
import Darwin

/// Chromium inside the app (CEF). Started the first time a tab opens a Chromium page,
/// never before: until then the app doesn't load the framework at all.
///
/// Its DevTools protocol runs over a private pipe (`DevToolsPipe`), not a port: only
/// the app talks to Chromium, and agents reach their own tab through the gate.
/// `SMART_TERMINAL_CHROMIUM_PORT` opens a plain TCP port instead, for development.
@MainActor
enum ChromiumRuntime {
    private(set) static var debuggingPort: Int?
    private(set) static var startError: String?
    fileprivate static var pages: [ObjectIdentifier: ChromiumPage] = [:]

    static var isRunning: Bool { CefRuntime.shared.isInitialized }

    /// The DevTools HTTP endpoint, when started with a port for development.
    static var debuggingURL: URL? { debuggingPort.flatMap { URL(string: "http://127.0.0.1:\($0)") } }

    static let dataDirectory = ShellIntegration.supportDir.appendingPathComponent("Chromium", isDirectory: true)

    /// Starts Chromium if it isn't running. False if it can't (framework missing, ...).
    @discardableResult
    static func start() -> Bool {
        if isRunning { return true }
        if startError != nil { return false }
        var config = CefConfiguration()
        config.rootCachePath = dataDirectory
        config.cachePath = dataDirectory.appendingPathComponent("Default", isDirectory: true)
        config.persistSessionCookies = true
        let port = ProcessInfo.processInfo.environment["SMART_TERMINAL_CHROMIUM_PORT"].flatMap(Int.init)
        if let port {
            config.remoteDebuggingPort = port
        } else if DevToolsPipe.isReserved {
            config.extraCommandLineSwitches["remote-debugging-pipe"] = .some(nil)
        }
        // An agent's page in a tab you aren't looking at keeps running at full speed,
        // as it would in headless Chrome: screenshots, timers and animations all work.
        for flag in ["disable-renderer-backgrounding", "disable-backgrounding-occluded-windows",
                     "disable-background-timer-throttling"] {
            config.extraCommandLineSwitches[flag] = .some(nil)
        }
        config.logFile = dataDirectory.appendingPathComponent("chromium.log")
        config.logSeverity = .warning
        do {
            try CefRuntime.shared.initialize(configuration: config)
        } catch {
            startError = "\(error)"
            NSLog("Chromium failed to start: \(error)")
            return false
        }
        // Quitting asks first (running processes) in applicationShouldTerminate; only
        // once that's settled does `shutdown()` close the pages. CefKit's own handler
        // would close them before the question, so a cancelled quit lost them.
        CEFApplication.setTerminateHandler(nil)
        debuggingPort = port
        ChromiumTargets.shared.start()
        return true
    }

    /// At quit: closes every page, lets Chromium finish (cookies reach the disk), stops it.
    static func shutdown() {
        guard isRunning else { return }
        for page in pages.values { page.close() }
        let deadline = Date().addingTimeInterval(2)
        while pages.values.contains(where: { $0.browser != nil }), Date() < deadline {
            cef_do_message_loop_work()
            usleep(10_000)
        }
        CefRuntime.shared.shutdown()
    }
}

/// Chromium's pages as DevTools targets, from the app's own discovery on the pipe, so
/// a page knows its target id (the gate names pages by it).
@MainActor
final class ChromiumTargets {
    static let shared = ChromiumTargets()

    struct Info: Equatable {
        var targetID: String
        var type: String
        var url: String
        var contextID: String
    }

    private(set) var targets: [String: Info] = [:]
    private var waiters: [(match: (Info) -> Bool, resume: (Info?) -> Void)] = []

    func start() {
        let connection = DevToolsConnection.shared
        connection.open()
        connection.onMessage = { data in ChromiumGate.shared.route(data) }
        connection.send(method: "Target.setDiscoverTargets", params: ["discover": true])
    }

    /// A browser-level event on the app's own session.
    func handle(method: String, params: [String: Any]) {
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard let raw = params["targetInfo"] as? [String: Any], let id = raw["targetId"] as? String else { return }
            let info = Info(targetID: id, type: raw["type"] as? String ?? "", url: raw["url"] as? String ?? "",
                            contextID: raw["browserContextId"] as? String ?? "")
            targets[id] = info
            if let i = waiters.firstIndex(where: { $0.match(info) }) {
                waiters.remove(at: i).resume(info)
            }
        case "Target.targetDestroyed":
            if let id = params["targetId"] as? String { targets[id] = nil }
        default:
            break
        }
    }

    /// The first target (already known or yet to appear) that `match` accepts.
    func wait(timeout: TimeInterval = 10, for match: @escaping (Info) -> Bool) async -> Info? {
        if let known = targets.values.first(where: match) { return known }
        return await withCheckedContinuation { (cont: CheckedContinuation<Info?, Never>) in
            var done = false
            let resume: (Info?) -> Void = { info in
                guard !done else { return }
                done = true
                cont.resume(returning: info)
            }
            waiters.append((match, resume))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { resume(nil) }
        }
    }
}

/// A page in Chromium. The browser is created at once, in the parking window if the
/// pane isn't on screen: an agent's page has to run whether you look at it or not.
@MainActor
final class ChromiumPage: PageEngine, CefBrowserDelegate {
    private let host = ChromiumHostView()
    private let profile: CefProfile?
    fileprivate private(set) var browser: CefBrowser?
    private var pendingURL: URL?
    private var state = PageState()
    var view: NSView { host }
    var onChange: ((PageState) -> Void)?
    var onPageClosed: (() -> Void)?

    init(profile: CefProfile?) {
        self.profile = profile
        host.page = self
        ChromiumRuntime.pages[ObjectIdentifier(self)] = self
        ParkingWindow.shared.park(host)
    }

    /// Creates the browser once the host view is in a window (it always is: here or parked).
    fileprivate func createBrowserIfNeeded() {
        guard browser == nil, host.window != nil, pendingURL != nil, ChromiumRuntime.start() else { return }
        var options = CefBrowserOptions()
        options.backgroundColor = .windowBackgroundColor
        options.profile = profile
        let url = pendingURL!
        pendingURL = nil
        let b = CefBrowser.createBrowser(parentView: host, bounds: host.bounds, url: url,
                                         options: options, delegate: self)
        guard b.id >= 0 else { return }
        browser = b
        host.adopt(b.nativeView)
    }

    /// Opens the page on `url` and reports its DevTools target, as the page's own
    /// DevTools agent names it, once Chromium lists it as a page.
    func open(_ url: URL) async -> ChromiumTargets.Info? {
        load(url)
        guard let browser, let id = await PageTargetQuery.targetID(of: browser) else { return nil }
        return await ChromiumTargets.shared.wait { $0.targetID == id && $0.type == "page" }
    }

    func load(_ url: URL) {
        if let browser { browser.load(url) } else { pendingURL = url; createBrowserIfNeeded() }
        state.url = url
        report()
    }

    func back() { browser?.goBack() }
    func forward() { browser?.goForward() }
    func reload() { browser?.reload() }
    func stop() { browser?.stopLoading() }
    func showInspector() { browser?.showDevTools() }

    func evaluate(_ script: String, completion: @escaping (String?) -> Void) {
        browser?.executeJavaScript(script)
        completion(nil) // CEF runs it in the renderer; no result comes back this way
    }

    func close() {
        guard let browser else {
            ChromiumRuntime.pages[ObjectIdentifier(self)] = nil
            host.removeFromSuperview()
            return
        }
        let w = ChromiumPage.closingWindow(for: host)
        closeWindow = w
        browser.close(force: true)
        // CEF ends an embedded page when its view goes: release it and its window.
        DispatchQueue.main.async { [host] in
            host.subviews.forEach { $0.removeFromSuperview() }
            w.close()
        }
    }

    /// CEF closes an embedded page by closing the window it's in (CefKit lets it). The
    /// pane's window and the parking window must stay, so a closing page first moves to
    /// an invisible window of its own, which goes with it.
    private var closeWindow: NSWindow?

    private static func closingWindow(for view: NSView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: view.bounds.size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.isExcludedFromWindowsMenu = true
        w.collectionBehavior = [.transient, .ignoresCycle]
        view.removeFromSuperview()
        w.contentView = NSView(frame: NSRect(origin: .zero, size: view.bounds.size))
        w.contentView?.addSubview(view)
        w.orderBack(nil)
        return w
    }

    private func report() { onChange?(state) }

    // MARK: CefBrowserDelegate

    func browser(_ b: CefBrowser, didChangeTitle title: String) { state.title = title; report() }
    func browser(_ b: CefBrowser, didChangeURL url: URL?) {
        state.url = url
        report()
    }
    func browser(_ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        state.isLoading = isLoading
        state.canGoBack = canGoBack
        state.canGoForward = canGoForward
        if !isLoading { state.progress = 1 }
        report()
    }
    func browser(_ b: CefBrowser, didChangeProgress progress: Double) { state.progress = progress; report() }

    /// Links that open a new window load here instead, as in the WebKit pane.
    func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        .openInCurrentBrowser
    }

    /// CEF closes no window for an embedded page (patched CefKit): either the app is
    /// closing it (`close()` already removes the view) or the page called
    /// window.close(), which closes it the same way.
    func browserWantsToClose(_ b: CefBrowser) {
        if closeWindow == nil { onPageClosed?() }
    }

    func browserDidClose(_ b: CefBrowser) {
        browser = nil
        closeWindow?.orderOut(nil)
        closeWindow = nil
        host.removeFromSuperview()
        ChromiumRuntime.pages[ObjectIdentifier(self)] = nil
    }
}

/// Holds Chromium's own view and keeps it the size of the pane. The pane moves this
/// view in and out; Chromium's view goes with it.
@MainActor
final class ChromiumHostView: NSView {
    weak var page: ChromiumPage?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { page?.createBrowserIfNeeded() }
    }

    func adopt(_ native: NSView?) {
        guard let native else { return }
        if native.superview !== self { native.removeFromSuperview(); addSubview(native) }
        native.frame = bounds
        native.autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }
}

/// Where Chromium pages wait while no pane shows them: a window you never see (fully
/// transparent, clicks pass through) but that macOS counts as on screen, so Chromium
/// keeps drawing. Pages are parked at a desktop size, which is what an agent's
/// screenshots and layout see.
@MainActor
final class ParkingWindow {
    static let shared = ParkingWindow()
    static let pageSize = NSSize(width: 1280, height: 800)

    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.pageSize),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isExcludedFromWindowsMenu = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        w.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        w.contentView = NSView(frame: NSRect(origin: .zero, size: Self.pageSize))
        w.orderBack(nil)
        return w
    }()

    func park(_ view: NSView) {
        guard view.window !== window else { return }
        view.removeFromSuperview()
        view.frame = NSRect(origin: .zero, size: Self.pageSize)
        view.autoresizingMask = []
        window.contentView?.addSubview(view)
    }
}
