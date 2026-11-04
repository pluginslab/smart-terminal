import AppKit
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
        if let existing = browsers[tabID], existing.engineKind != engine { close(tabID) }
        let b = browsers[tabID] ?? BrowserState(engine: engine)
        browsers[tabID] = b
        hidden.remove(tabID)
        b.load(url)
        return b
    }

    func close(_ tabID: UUID) {
        hidden.remove(tabID)
        browsers.removeValue(forKey: tabID)?.close()
    }
}
