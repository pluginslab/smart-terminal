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
    /// Opened empty from the toolbar button: the address field takes the cursor.
    var wantsAddressFocus = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // logins and cookies shared by every tab, kept across launches
        // Web Inspector in the app: "Inspect Element" in the page's context menu and the
        // dev-tools button. A private WebKit preference, set the way Safari's own is.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true // also listed in Safari's Develop menu
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

    /// Opens the Web Inspector for this page (WebKit's `_inspector`, the object behind
    /// the context menu's Inspect Element).
    func showInspector() {
        (webView.value(forKey: "_inspector") as? NSObject)?.perform(NSSelectorFromString("show"))
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
    /// Browsers hidden with the toolbar button: page and history kept for when it's shown again.
    private(set) var hidden: Set<UUID> = []
    /// Pane widths per tab, so each keeps the width you dragged it to.
    var widths: [UUID: Double] = [:]

    func browser(for tabID: UUID?) -> BrowserState? { tabID.flatMap { browsers[$0] } }

    /// The pane to draw for a tab: it has a browser and it isn't hidden.
    func visibleBrowser(for tabID: UUID?) -> BrowserState? {
        guard let tabID, !hidden.contains(tabID) else { return nil }
        return browsers[tabID]
    }

    /// The toolbar button: shows an empty browser ready for an address, or hides and
    /// re-shows the tab's existing one without losing its page.
    func toggle(_ tabID: UUID) {
        if browsers[tabID] == nil {
            let b = BrowserState()
            b.wantsAddressFocus = true
            browsers[tabID] = b
        } else if hidden.contains(tabID) {
            hidden.remove(tabID)
        } else {
            hidden.insert(tabID)
        }
    }

    /// Shows `url` in the tab's pane, creating the pane if needed.
    @discardableResult
    func open(_ url: URL, in tabID: UUID) -> BrowserState {
        let b = browsers[tabID] ?? BrowserState()
        browsers[tabID] = b
        hidden.remove(tabID)
        b.load(url)
        return b
    }

    func close(_ tabID: UUID) {
        hidden.remove(tabID)
        guard let b = browsers.removeValue(forKey: tabID) else { return }
        b.webView.stopLoading()
        b.webView.removeFromSuperview()
    }
}
