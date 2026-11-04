import AppKit
import SwiftUI
import SmartTerminalCore

/// The tab's browser beside its terminal: navigation bar on top, the page below,
/// and a handle on the leading edge to resize it.
struct BrowserPane: View {
    let tabID: UUID
    let browser: BrowserState
    let model: AppModel

    static let minWidth: CGFloat = 320
    @State private var dragStart: Double?

    private var width: Double { model.browsers.widths[tabID] ?? 560 }

    var body: some View {
        VStack(spacing: 0) {
            BrowserNavigationBar(browser: browser) { model.browsers.close(tabID) }
            if let page = browser.current {
                PageContainer(page: page.engine.view).id(page.id)
            } else {
                ContentUnavailableView("No pages", systemImage: "macwindow",
                                       description: Text("The agent closed its last page."))
            }
        }
        // Gives way before the terminal does: down to its minimum, then they share.
        .frame(minWidth: Self.minWidth, idealWidth: width, maxWidth: width)
        .background(.background)
        .overlay(alignment: .leading) {
            Divider().overlay {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.columnResize.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            let start = dragStart ?? width
                            dragStart = start
                            model.browsers.widths[tabID] = max(Self.minWidth, start - g.translation.width)
                        }
                        .onEnded { _ in dragStart = nil })
            }
        }
    }
}

/// Back, forward, reload or stop, the address, open elsewhere, close; a thin
/// progress line under it while a page loads.
private struct BrowserNavigationBar: View {
    let browser: BrowserState
    let close: () -> Void
    @State private var address = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 4) {
            NavButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: browser.canGoBack, action: browser.back)
                .keyboardShortcut("[", modifiers: .command)
            NavButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: browser.canGoForward, action: browser.forward)
                .keyboardShortcut("]", modifiers: .command)
            NavButton(symbol: browser.isLoading ? "xmark" : "arrow.clockwise",
                      help: browser.isLoading ? "Stop" : "Reload (⌘R)", action: browser.reloadOrStop)
                .keyboardShortcut("r", modifiers: .command)
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused($editing)
                .onSubmit { browser.go(address); editing = false }
                .onExitCommand { address = shown; editing = false }
            if browser.pages.count > 1 { PageMenu(browser: browser) }
            if case .agent = browser.owner { AgentBadge() }
            NavButton(symbol: "hammer", help: "Web Inspector (⌥⌘I)", enabled: browser.url != nil,
                      action: browser.showInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
            NavButton(symbol: "safari", help: "Open in Default Browser", enabled: browser.url != nil,
                      action: browser.openInDefaultBrowser)
            NavButton(symbol: "xmark.circle.fill", help: "Close Browser", action: close)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Divider()
                if browser.isLoading {
                    GeometryReader { geo in
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * max(0.05, browser.progress), height: 2)
                            .animation(.easeOut(duration: 0.2), value: browser.progress)
                    }
                    .frame(height: 2)
                }
            }
        }
        .onAppear {
            address = shown
            if browser.wantsAddressFocus {
                browser.wantsAddressFocus = false
                DispatchQueue.main.async { editing = true }
            }
        }
        // Follows the page (links, redirects, back/forward), but never while you type.
        .onChange(of: browser.url) { _, _ in if !editing { address = shown } }
        .help(browser.title)
    }

    /// The address as shown when not editing.
    private var shown: String { browser.url?.absoluteString ?? "" }
}

/// An agent's pages: which one the pane shows. The agent keeps working in all of them.
private struct PageMenu: View {
    let browser: BrowserState

    var body: some View {
        Menu {
            ForEach(browser.pages) { page in
                Toggle(isOn: Binding(get: { browser.current?.id == page.id }, set: { _ in browser.select(page) })) {
                    Text(page.state.title.isEmpty ? (page.state.url?.absoluteString ?? "New page") : page.state.title)
                }
            }
        } label: {
            Label("\(browser.pages.count)", systemImage: "square.on.square").font(.callout).monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(browser.pages.count) pages")
    }
}

/// The pane is an agent's: it drives these pages through the DevTools protocol.
private struct AgentBadge: View {
    var body: some View {
        Label("Agent", systemImage: "sparkles")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ClaudeGlyph.claudeOrange)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(ClaudeGlyph.claudeOrange.opacity(0.14)))
            .help("An agent drives this browser. Its pages run in a profile of their own; it sees none of yours.")
    }
}

private struct NavButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Hosts the tab's page view (either engine's). The view belongs to the tab's
/// `BrowserState`; this only reparents it, the way `TerminalContainer` does for terminals.
struct PageContainer: NSViewRepresentable {
    let page: NSView

    func makeNSView(context: Context) -> NSView { NSView() }

    /// The pane goes (tab switch, hidden): Chromium pages wait in the parking window,
    /// still running, rather than leave every window.
    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for case let host as ChromiumHostView in container.subviews { ParkingWindow.shared.park(host) }
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard page.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        page.removeFromSuperview()
        page.frame = container.bounds
        page.autoresizingMask = [.width, .height]
        container.addSubview(page)
    }
}
