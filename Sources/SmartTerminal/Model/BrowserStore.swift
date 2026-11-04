import AppKit
import CefKit
import Observation
import SmartTerminalCore

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
            let b = BrowserState(engine: .preferred)
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
    func open(_ url: URL, in tabID: UUID, engine: BrowserEngine = .preferred) -> BrowserState {
        // A pane in the other engine is replaced: a page can't move between engines.
        // An agent's pane stays the agent's: your page opens in a pane of your own.
        if let existing = browsers[tabID], existing.engineKind != engine || existing.owner != .user { close(tabID) }
        let b = browsers[tabID] ?? BrowserState(engine: engine)
        browsers[tabID] = b
        hidden.remove(tabID)
        b.load(url)
        return b
    }

    func close(_ tabID: UUID) {
        hidden.remove(tabID)
        guard let b = browsers.removeValue(forKey: tabID) else { return }
        b.close()
        // Closing an agent's pane ends its browser: the agent's next call says so.
        if case .agent = b.owner { ChromiumGate.shared.tabClosed(tabID) }
    }

    /// An agent's pane in the tab, in its own Chromium profile. It takes the tab's pane;
    /// another agent's browser there keeps running out of sight (its agent holds it)
    /// and comes back when this one ends. A pane of yours is closed.
    func openAgent(id: String, in tabID: UUID, profile: CefProfile) -> BrowserState {
        if let existing = browsers[tabID], existing.owner == .user {
            browsers[tabID] = nil
            existing.close()
        }
        let b = BrowserState(engine: .chromium, owner: .agent(id: id), profile: profile)
        browsers[tabID] = b
        hidden.remove(tabID)
        return b
    }

    /// An agent's browser ended: its pages close, and the tab shows the agent's
    /// browser that's left there, if any.
    func closeAgent(_ browser: BrowserState, in tabID: UUID, next: BrowserState?) {
        browser.close()
        guard browsers[tabID] === browser else { return }
        browsers[tabID] = next
    }
}
