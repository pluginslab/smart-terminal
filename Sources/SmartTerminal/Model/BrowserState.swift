import AppKit
import CefKit
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
    /// Laid out as a phone (the pane's Mobile mode, or an agent's mobile viewport).
    var isMobile = false
}

/// One engine's page: the view it draws in, and the commands the navigation bar sends.
@MainActor
protocol PageEngine: AnyObject {
    var view: NSView { get }
    /// Set by `BrowserPage`; the engine calls it whenever its state changes.
    var onChange: ((PageState) -> Void)? { get set }
    /// Set by `BrowserState`: the page closed itself (`window.close()`).
    var onPageClosed: (() -> Void)? { get set }
    func load(_ url: URL)
    func back()
    func forward()
    func reload()
    func stop()
    func showInspector()
    /// Whether the engine has a Mobile mode (Chromium).
    var supportsMobile: Bool { get }
    /// Lays the page out as a phone, or back on the desktop.
    func setMobile(_ on: Bool)
    /// Runs `script` in the page and hands back its result as text (debug channel).
    func evaluate(_ script: String, completion: @escaping (String?) -> Void)
    /// The page is gone for good: release it.
    func close()
}

/// One page in a pane, and what it shows.
@MainActor
@Observable
final class BrowserPage: Identifiable {
    let id = UUID()
    @ObservationIgnored let engine: PageEngine
    private(set) var state = PageState()

    init(engine: PageEngine) {
        self.engine = engine
        engine.onChange = { [weak self] s in if self?.state != s { self?.state = s } }
    }
}

/// Who opens a tab's pages.
enum BrowserOwner: Equatable {
    /// You: `open`, ⌘-click, the toolbar.
    case user
    /// An agent, through the DevTools gate. `id` is the browser's id in the agent's tool.
    case agent(id: String)
}

/// One tab's browser: its pages live as long as the tab (or until you close the pane),
/// so they keep their history and scroll position across tab switches.
///
/// A pane you open has one page. One an agent drives can have several (it opens
/// tabs); the navigation bar then offers them in a menu.
@MainActor
@Observable
final class BrowserState {
    let engineKind: BrowserEngine
    let owner: BrowserOwner
    /// Chromium's profile for the pages (an agent's is its own, in memory). Nil: the
    /// engine's default, shared by the pages you open, logins kept across launches.
    @ObservationIgnored let profile: CefProfile?
    private(set) var pages: [BrowserPage] = []
    private(set) var selectedID: UUID?
    /// Opened empty from the toolbar button: the address field takes the cursor.
    var wantsAddressFocus = false

    init(engine: BrowserEngine, owner: BrowserOwner = .user, profile: CefProfile? = nil) {
        engineKind = engine
        self.owner = owner
        self.profile = profile
        if owner == .user { addPage(select: true) }
    }

    var current: BrowserPage? { pages.first { $0.id == selectedID } ?? pages.first }

    @discardableResult
    func addPage(select: Bool) -> BrowserPage {
        let engine: PageEngine = switch engineKind {
        case .webKit: WebKitPage()
        case .chromium: ChromiumPage(profile: profile)
        }
        let page = BrowserPage(engine: engine)
        engine.onPageClosed = { [weak self, weak page] in
            if let self, let page { self.closePage(page) }
        }
        pages.append(page)
        if select || selectedID == nil { selectedID = page.id }
        return page
    }

    func select(_ page: BrowserPage) { selectedID = page.id }

    func closePage(_ page: BrowserPage) {
        page.engine.close()
        pages.removeAll { $0.id == page.id }
        if selectedID == page.id { selectedID = pages.last?.id }
    }

    private var state: PageState { current?.state ?? PageState() }
    var url: URL? { state.url }
    var title: String { state.title }
    var isLoading: Bool { state.isLoading }
    var progress: Double { state.progress }
    var canGoBack: Bool { state.canGoBack }
    var canGoForward: Bool { state.canGoForward }

    func load(_ url: URL) { (current ?? addPage(select: true)).engine.load(url) }

    /// Address-bar entry: a URL, a host, or words to search for.
    func go(_ input: String) {
        if let url = BrowserAddress.url(from: input) { load(url) }
    }

    func back() { current?.engine.back() }
    func forward() { current?.engine.forward() }
    func reloadOrStop() {
        if isLoading { current?.engine.stop() } else { current?.engine.reload() }
    }
    func showInspector() { current?.engine.showInspector() }
    var isMobile: Bool { state.isMobile }
    var supportsMobile: Bool { current?.engine.supportsMobile ?? false }
    func toggleMobile() { current.map { $0.engine.setMobile(!$0.state.isMobile) } }

    func openInDefaultBrowser() {
        if let url { NSWorkspace.shared.open(url) }
    }

    func close() {
        pages.forEach { $0.engine.close() }
        pages = []
    }
}
