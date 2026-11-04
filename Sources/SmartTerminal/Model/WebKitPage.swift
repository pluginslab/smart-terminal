import AppKit
import WebKit

/// A page in Safari's engine.
@MainActor
final class WebKitPage: NSObject, PageEngine, WKUIDelegate {
    let webView: WKWebView
    var view: NSView { webView }
    var onChange: ((PageState) -> Void)?
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

    /// Links that open a new window (target="_blank", window.open) load here
    /// instead, so they land in this pane's history rather than nowhere.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}
