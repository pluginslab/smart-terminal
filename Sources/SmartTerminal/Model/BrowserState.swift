import AppKit
import Observation
import SmartTerminalCore

/// Which engine draws a tab's browser pane.
enum BrowserEngine: String, CaseIterable, Sendable {
    /// Safari's engine (WKWebView): light, the default for pages you open.
    case webKit
    /// Chromium (CEF): speaks the Chrome DevTools Protocol, so agents can drive it.
    case chromium

    var displayName: String { self == .webKit ? "WebKit" : "Chromium" }

    /// The engine new browser panes use, chosen in View ▸ Browser Engine.
    static var preferred: BrowserEngine {
        get { UserDefaults.standard.string(forKey: "browserEngine").flatMap(Self.init) ?? .webKit }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "browserEngine") }
    }
}

/// What a page engine tells its pane. Both engines report the same things.
struct PageState: Equatable {
    var url: URL?
    var title = ""
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
}

/// One engine's page: the view it draws in, and the commands the navigation bar sends.
@MainActor
protocol PageEngine: AnyObject {
    var view: NSView { get }
    /// Set by `BrowserState`; the engine calls it whenever its state changes.
    var onChange: ((PageState) -> Void)? { get set }
    func load(_ url: URL)
    func back()
    func forward()
    func reload()
    func stop()
    func showInspector()
    /// Runs `script` in the page and hands back its result as text (debug channel).
    func evaluate(_ script: String, completion: @escaping (String?) -> Void)
    /// The pane is gone for good: release the page.
    func close()
}

/// One tab's browser: a page that lives as long as the tab (or until you close the
/// pane), so its page, history and scroll position survive tab switches.
@MainActor
@Observable
final class BrowserState {
    let engineKind: BrowserEngine
    @ObservationIgnored let engine: PageEngine
    private(set) var page = PageState()
    /// Opened empty from the toolbar button: the address field takes the cursor.
    var wantsAddressFocus = false

    init(engine kind: BrowserEngine) {
        engineKind = kind
        switch kind {
        case .webKit: engine = WebKitPage()
        case .chromium: engine = ChromiumPage()
        }
        engine.onChange = { [weak self] state in
            if self?.page != state { self?.page = state }
        }
    }

    var url: URL? { page.url }
    var title: String { page.title }
    var isLoading: Bool { page.isLoading }
    var progress: Double { page.progress }
    var canGoBack: Bool { page.canGoBack }
    var canGoForward: Bool { page.canGoForward }

    func load(_ url: URL) { engine.load(url) }

    /// Address-bar entry: a URL, a host, or words to search for.
    func go(_ input: String) {
        if let url = BrowserAddress.url(from: input) { load(url) }
    }

    func back() { engine.back() }
    func forward() { engine.forward() }
    func reloadOrStop() {
        if isLoading { engine.stop() } else { engine.reload() }
    }
    func showInspector() { engine.showInspector() }

    func openInDefaultBrowser() {
        if let url { NSWorkspace.shared.open(url) }
    }

    func close() { engine.close() }
}
