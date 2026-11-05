import AppKit
import WebKit

/// A page in Safari's engine.
@MainActor
final class WebKitPage: NSObject, PageEngine, WKUIDelegate {
    let webView: WKWebView
    var view: NSView { webView }
    var onChange: ((PageState) -> Void)?
    var onPageClosed: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // logins and cookies shared by every tab, kept across launches
        // Web Inspector in the app: "Inspect Element" in the page's context menu and the
        // dev-tools button. A private WebKit preference, set the way Safari's own is.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // WebKit alone leaves out Safari's "Version/… Safari/…" tail, and sites that sniff
        // for a supported browser (Slack) turn it away. Identify as the Safari on this Mac.
        config.applicationNameForUserAgent = Self.safariUserAgentSuffix
        #if DEBUG
        // Tests open popups from script (they can't click): only with this set.
        if ProcessInfo.processInfo.environment["SMART_TERMINAL_TEST_POPUPS"] == "1" {
            config.preferences.javaScriptCanOpenWindowsAutomatically = true
        }
        #endif
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true // also listed in Safari's Develop menu
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        webView.uiDelegate = self
        // KVO arrives on the main thread for WKWebView's properties.
        let changed: (WKWebView) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
        observations = [
            webView.observe(\.url) { w, _ in changed(w) },
            webView.observe(\.title) { w, _ in changed(w) },
            webView.observe(\.isLoading) { w, _ in changed(w) },
            webView.observe(\.estimatedProgress) { w, _ in changed(w) },
            webView.observe(\.canGoBack) { w, _ in changed(w) },
            webView.observe(\.canGoForward) { w, _ in changed(w) },
        ]
    }

    private func report() {
        onChange?(PageState(url: webView.url, title: webView.title ?? "", isLoading: webView.isLoading,
                            progress: webView.estimatedProgress,
                            canGoBack: webView.canGoBack, canGoForward: webView.canGoForward))
    }

    /// "Version/26.5.2 Safari/605.1.15", from the Safari installed here.
    static let safariUserAgentSuffix: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary
        let version = safari?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    /// Opens the Web Inspector for this page (WebKit's `_inspector`, the object behind
    /// the context menu's Inspect Element).
    func showInspector() {
        (webView.value(forKey: "_inspector") as? NSObject)?.perform(NSSelectorFromString("show"))
    }

    func evaluate(_ script: String, completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript(script) { result, _ in completion(result.map { "\($0)" }) }
    }

    func close() {
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    /// The page called window.close(): it leaves the pane.
    func webViewDidClose(_ webView: WKWebView) { onPageClosed?() }

    /// A link that opens a new window (target="_blank") loads here, in the pane's
    /// history. A page that opens one itself (window.open: "Sign in with Google" and
    /// other OAuth popups) gets a real popup window: the sign-in hands its result back
    /// through `window.opener` and closes the popup, which a pane-loaded copy can't do.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
            return nil
        }
        return PopupWindow.open(configuration: configuration, features: windowFeatures,
                                over: webView.window).webView
    }
}

/// A page's popup (window.open), in a small window of its own over the pane's window.
/// It must use the configuration WebKit hands over: that is what ties it to its opener.
@MainActor
final class PopupWindow: NSObject, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private static var open: Set<PopupWindow> = []

    static func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                     over parent: NSWindow?) -> PopupWindow {
        let popup = PopupWindow(configuration: configuration, features: features, over: parent)
        open.insert(popup)
        return popup
    }

    private init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, over parent: NSWindow?) {
        let size = NSSize(width: features.width.map { CGFloat($0.doubleValue) } ?? 500,
                          height: features.height.map { CGFloat($0.doubleValue) } ?? 640)
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        webView.isInspectable = true
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        webView.uiDelegate = self
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        window.title = "Loading…"
        if let parent {
            let p = parent.frame
            window.setFrameOrigin(NSPoint(x: p.midX - size.width / 2, y: p.midY - size.height / 2))
        } else {
            window.center()
        }
        titleObservation = webView.observe(\.title) { [weak self] w, _ in
            MainActor.assumeIsolated { self?.window.title = w.title ?? "" }
        }
        window.makeKeyAndOrderFront(nil)
    }

    private var titleObservation: NSKeyValueObservation?

    /// The page closed itself (window.close(), the end of an OAuth sign-in).
    func webViewDidClose(_ webView: WKWebView) { window.close() }

    /// A popup's own popups get windows too.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        PopupWindow.open(configuration: configuration, features: windowFeatures, over: window).webView
    }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        titleObservation = nil
        Self.open.remove(self)
    }
}
