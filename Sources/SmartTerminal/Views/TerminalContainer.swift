import AppKit
import SwiftUI
import SmartTerminalCore

/// Hosts the active tab's terminal view. The view itself lives in the
/// SessionRegistry; this container only reparents it, so shells and scrollback
/// survive tab switches and moves between windows.
struct TerminalContainer: NSViewRepresentable {
    let tab: TerminalTab?
    let model: AppModel

    func makeNSView(context: Context) -> ContainerView { ContainerView() }

    func updateNSView(_ container: ContainerView, context: Context) {
        container.marginColor = model.sessions.profile.background
        guard let tab else { container.show(nil); return }
        let session = model.sessions.session(for: tab.id, cwd: tab.cwd)
        container.show(session.view)
    }

    final class ContainerView: NSView {
        private weak var current: NSView?
        /// Breathing room around the grid, painted in the profile background.
        static let margin = NSEdgeInsets(top: 4, left: 6, bottom: 2, right: 2)
        var marginColor: NSColor = .textBackgroundColor {
            didSet { if marginColor != oldValue { needsDisplay = true } }
        }

        override var isFlipped: Bool { true }

        private var contentRect: NSRect {
            let m = Self.margin
            return NSRect(x: m.left, y: m.top, width: max(0, bounds.width - m.left - m.right),
                          height: max(0, bounds.height - m.top - m.bottom))
        }

        override func layout() {
            super.layout()
            current?.frame = contentRect
        }

        /// Fills only the margins, so translucent profiles are not painted twice.
        override func draw(_ dirtyRect: NSRect) {
            marginColor.setFill()
            let inner = contentRect
            [NSRect(x: 0, y: 0, width: bounds.width, height: inner.minY),
             NSRect(x: 0, y: inner.maxY, width: bounds.width, height: bounds.height - inner.maxY),
             NSRect(x: 0, y: inner.minY, width: inner.minX, height: inner.height),
             NSRect(x: inner.maxX, y: inner.minY, width: bounds.width - inner.maxX, height: inner.height)]
                .forEach { $0.fill() }
        }

        func show(_ view: NSView?) {
            guard view !== current || view?.superview !== self else { return }
            current?.removeFromSuperview()
            current = view
            guard let view else { return }
            view.removeFromSuperview()
            view.frame = contentRect
            view.autoresizingMask = []
            addSubview(view)
            focus()
        }

        func focus() {
            guard let current else { return }
            // Defer until the view is in a window (first show happens mid-layout).
            DispatchQueue.main.async { [weak self, weak current] in
                guard let self, let current, current.superview === self else { return }
                self.window?.makeFirstResponder(current)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focus()
        }
    }
}
