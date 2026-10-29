import AppKit
import Observation
import WebKit
import SmartTerminalCore

/// One tab's browser: a WebKit view that lives as long as the tab (or until you
/// close the pane), so its page, history and scroll position survive tab switches.
@MainActor
@Observable
final class BrowserState: NSObject, WKUIDelegate {
    let webView: WKWebView
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // logins and cookies shared by every tab, kept across launches
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        webView.uiDelegate = self
        // KVO arrives on the main thread for WKWebView's properties.
        observations = [
            webView.observe(\.url) { [weak self] w, _ in MainActor.assumeIsolated { self?.url = w.url } },
            webView.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            webView.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.isLoading = w.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] w, _ in MainActor.assumeIsolated { self?.progress = w.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
        ]
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    /// Links that open a new window (target="_blank", window.open) load here
    /// instead, so they land in this pane's history rather than nowhere.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    /// Address-bar entry: a URL, a host, or words to search for.
    func go(_ input: String) {
        if let url = BrowserAddress.url(from: input) { load(url) }
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func openInDefaultBrowser() {
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// The browsers of all tabs. A tab has one only after something opened a page in it.
@MainActor
@Observable
final class BrowserStore {
    private(set) var browsers: [UUID: BrowserState] = [:]
    /// Pane widths per tab, so each keeps the width you dragged it to.
    var widths: [UUID: Double] = [:]

    func browser(for tabID: UUID?) -> BrowserState? { tabID.flatMap { browsers[$0] } }

    /// Shows `url` in the tab's pane, creating the pane if needed.
    @discardableResult
    func open(_ url: URL, in tabID: UUID) -> BrowserState {
        let b = browsers[tabID] ?? BrowserState()
        browsers[tabID] = b
        b.load(url)
        return b
    }

    func close(_ tabID: UUID) {
        guard let b = browsers.removeValue(forKey: tabID) else { return }
        b.webView.stopLoading()
        b.webView.removeFromSuperview()
    }
}
