import SwiftUI
import UIKit
import SwiftTerm

/// Whether the on-screen keyboard is up. A hardware keyboard only shows the small
/// shortcut bar, which doesn't count.
@MainActor @Observable
final class KeyboardWatcher {
    static let shared = KeyboardWatcher()
    private(set) var visible = false

    private init() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds
            let shown = frame.intersection(screen).height > 120
            MainActor.assumeIsolated { self?.visible = shown }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visible = false }
        }
    }
}

/// The keys a session needs when there's no keyboard: answering Claude (arrows,
/// return, esc), its mode (⇧⇥), stopping a command (^C). Then the keyboard toggle,
/// and dictation next to return.
struct KeyBar: View {
    @Bindable var model: PadModel
    let session: String

    var body: some View {
        let pane = model.pane(for: session)
        // While dictating, the other keys wait: a stray tap would land in the middle
        // of the text about to be typed. Return comes back once the text is in.
        let busy = model.dictation.isActive
        HStack(spacing: 6) {
            Group {
                Key(symbol: "keyboard", label: "Show Keyboard") {
                    _ = pane.view.becomeFirstResponder()
                }
                Separator()
                Key(text: "esc", label: "Escape") { pane.view.send(EscapeSequences.cmdEsc) }
                Key(text: "⇧tab", label: "Shift Tab") { pane.view.send([0x1b, 0x5b, 0x5a]) }
                Key(text: "tab", label: "Tab") { pane.view.send([0x09]) }
                Key(text: "^C", label: "Control C") { pane.view.send([0x03]) }
                ArrowPad { arrow(pane, $0) }
            }
            .disabled(busy)
            .opacity(busy ? 0.35 : 1)
            if model.dictation.state == .recording {
                Waveform(levels: model.dictation.levels)
                    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            } else {
                Spacer(minLength: 8)
            }
            if !busy {
                Button { pane.view.send([0x0d]) } label: {
                    Label("return", systemImage: "return")
                        .font(.system(size: 15, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.onSelection)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.selection).interactive(), in: .capsule)
                .accessibilityLabel("Return")
                .transition(.scale.combined(with: .opacity))
            }
            Separator().padding(.horizontal, 4)
            DictationButton(model: model, session: session, large: true)
        }
        .animation(.snappy(duration: 0.2), value: busy)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
        .background(Theme.bar)
        .overlay(alignment: .top) { Divider().overlay(Theme.line) }
    }



    private func arrow(_ pane: TerminalPane, _ a: Arrow) {
        let app = pane.view.getTerminal().applicationCursor
        let seq: [UInt8] = switch a {
        case .up: app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        case .down: app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        case .left: app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        case .right: app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
        }
        pane.view.send(seq)
    }
}

enum Arrow { case up, down, left, right }

/// All four arrows in one key: swipe from it in a direction to send that arrow,
/// one more for each further step of the same swipe, so a long drag walks down a
/// list. Lights up the direction it just sent.
private struct ArrowPad: View {
    let send: (Arrow) -> Void
    @State private var origin: CGSize = .zero
    @State private var last: Arrow?

    private let step: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 56, height: 36)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { g in
                        let dx = g.translation.width - origin.width
                        let dy = g.translation.height - origin.height
                        guard max(abs(dx), abs(dy)) >= step else { return }
                        let a: Arrow = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
                        send(a)
                        last = a
                        origin = g.translation
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        origin = .zero
                        last = nil
                    }
            )
            .accessibilityLabel("Arrow keys")
            .accessibilityHint("Swipe up, down, left or right")
            .accessibilityAdjustableAction { dir in
                send(dir == .increment ? .up : .down)
            }
    }

    private var symbol: String {
        switch last {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case nil: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

/// What the mic hears, as bars scrolling left with the newest at the right edge,
/// as voice messages show it. Only as many bars as the space between the keys and
/// the mic holds; older ones scroll off the left.
private struct Waveform: View {
    let levels: [Float]
    private let bar: CGFloat = 3
    private let gap: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            let fits = Int((size.width + gap) / (bar + gap))
            let shown = levels.suffix(fits)
            var x = size.width - bar
            for level in shown.reversed() {
                // A floor, so silence still reads as a quiet line rather than nothing.
                let h = max(3, CGFloat(level) * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(.red.opacity(0.85)))
                x -= bar + gap
            }
        }
        .accessibilityLabel("Recording")
    }
}

/// A short vertical hairline between key groups, centred on the keys. (A Divider
/// with a colour overlay ran into the home indicator's band below the bar.)
private struct Separator: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 26)
    }
}

/// One key: a glass capsule with a symbol or short text.
private struct Key: View {
    var symbol: String?
    var text: String?
    let label: String
    let action: () -> Void

    init(symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.action = action
    }

    init(text: String, label: String, action: @escaping () -> Void) {
        self.text = text; self.label = label; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .medium)) }
                else if let text { Text(text).font(.system(size: 15, weight: .semibold, design: .monospaced)) }
            }
            .frame(minWidth: 44, minHeight: 36)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(label)
    }
}
