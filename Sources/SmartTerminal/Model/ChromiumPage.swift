import AppKit
import CCef
import CCefAppKit
import CefKit
import Darwin

/// Chromium inside the app (CEF). Started the first time a tab opens a Chromium page,
/// never before: until then the app doesn't load the framework at all.
///
/// Its DevTools endpoint is what chrome-devtools-mcp connects to. It listens on
/// 127.0.0.1 only, on a port picked at start.
@MainActor
enum ChromiumRuntime {
    private(set) static var debuggingPort: Int?
    private(set) static var startError: String?
    fileprivate static var pages: [ObjectIdentifier: ChromiumPage] = [:]

    static var isRunning: Bool { CefRuntime.shared.isInitialized }

    /// The DevTools HTTP endpoint (`/json/version`, `/json/list`), once Chromium runs.
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
        let port = freeLocalPort()
        config.remoteDebuggingPort = port
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
        return true
    }

    /// At quit: closes every page, lets Chromium finish (cookies reach the disk), stops it.
    static func shutdown() {
        guard isRunning else { return }
        for page in pages.values { page.browser?.close(force: true) }
        let deadline = Date().addingTimeInterval(2)
        while pages.values.contains(where: { $0.browser != nil }), Date() < deadline {
            cef_do_message_loop_work()
            usleep(10_000)
        }
        CefRuntime.shared.shutdown()
    }

    /// A port nothing listens on now, for Chromium to take.
    private static func freeLocalPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// A page in Chromium. The browser itself is created once its view is in a window
/// (Chromium needs a parent view to draw into); until then a load waits.
@MainActor
final class ChromiumPage: PageEngine, CefBrowserDelegate {
    private let host = ChromiumHostView()
    fileprivate private(set) var browser: CefBrowser?
    private var pendingURL: URL?
    private var state = PageState()
    var view: NSView { host }
    var onChange: ((PageState) -> Void)?

    init() {
        host.page = self
        ChromiumRuntime.pages[ObjectIdentifier(self)] = self
    }

    /// Called by the host view when it lands in a window.
    fileprivate func createBrowserIfNeeded() {
        guard browser == nil, host.window != nil, ChromiumRuntime.start() else { return }
        var options = CefBrowserOptions()
        options.backgroundColor = .windowBackgroundColor
        let url = pendingURL ?? URL(string: "about:blank")!
        pendingURL = nil
        let b = CefBrowser.createBrowser(parentView: host, bounds: host.bounds, url: url,
                                         options: options, delegate: self)
        guard b.id >= 0 else { return }
        browser = b
        host.adopt(b.nativeView)
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
        if let browser { browser.close(force: true) } else { ChromiumRuntime.pages[ObjectIdentifier(self)] = nil }
        host.removeFromSuperview()
    }

    private func report() { onChange?(state) }

    // MARK: CefBrowserDelegate

    func browser(_ b: CefBrowser, didChangeTitle title: String) { state.title = title; report() }
    func browser(_ b: CefBrowser, didChangeURL url: URL?) { state.url = url; report() }
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

    func browserDidClose(_ b: CefBrowser) {
        browser = nil
        ChromiumRuntime.pages[ObjectIdentifier(self)] = nil
    }
}

/// Holds Chromium's own view and keeps it the size of the pane. The pane moves this
/// view between windows and tab switches; Chromium's view goes with it.
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
