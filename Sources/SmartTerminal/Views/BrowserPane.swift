import AppKit
import SwiftUI
import WebKit
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
            WebViewContainer(webView: browser.webView)
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

/// Hosts the tab's web view. The view belongs to the tab's `BrowserState`; this
/// container only reparents it, the way `TerminalContainer` does for terminals.
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
