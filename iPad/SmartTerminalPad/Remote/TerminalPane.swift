import UIKit
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

/// One tab's terminal: a SwiftTerm view fed by an SSH PTY that runs
/// `tmux new -A -s <session>` on the host. Kept alive while the app runs, so
/// switching tabs keeps scrollback and doesn't re-attach.
@MainActor
final class TerminalPane: NSObject, TerminalViewDelegate {
    enum State: Equatable { case idle, attaching, attached, ended }

    let session: String
    let view: TerminalView
    private(set) var state: State = .idle { didSet { onState?(state) } }
    var onState: ((State) -> Void)?
    var onTitle: ((String) -> Void)?

    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?

    init(session: String) {
        self.session = session
        view = PadTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.terminalDelegate = self
        Theme.apply(to: view)
    }

    /// Attaches over `client` unless already attached.
    func attach(using client: SSHClient) {
        guard state != .attaching, state != .attached else { return }
        state = .attaching
        let term = view.getTerminal()
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: max(term.cols, 20), terminalRowHeight: max(term.rows, 5),
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        let name = session
        task = Task { [weak self] in
            do {
                try await client.withPTY(request) { inbound, outbound in
                    await MainActor.run {
                        self?.writer = outbound
                        self?.state = .attached
                    }
                    // The PTY starts a login shell; hand it over to tmux straight away.
                    // `-A` attaches when the session exists, creates it otherwise.
                    try await outbound.write(ByteBuffer(string: "exec tmux new-session -A -s \(Host.quote(name))\n"))
                    for try await chunk in inbound {
                        let bytes: [UInt8]
                        switch chunk {
                        case .stdout(let b), .stderr(let b): bytes = Array(b.readableBytesView)
                        }
                        await MainActor.run { self?.view.feed(byteArray: bytes[...]) }
                    }
                }
            } catch {}
            await MainActor.run {
                self?.writer = nil
                self?.state = .ended
            }
        }
    }

    /// Types text into the session, as the keyboard would.
    func write(_ text: String) {
        guard let writer else { return }
        let buffer = ByteBuffer(string: text)
        Task { try? await writer.write(buffer) }
    }

    /// What is on the cursor's line before the cursor, for Whisper's prompt: in a
    /// Claude Code prompt box that is the sentence being dictated so far.
    func textBeforeCursor(maxChars: Int) -> String? {
        let terminal = view.getTerminal()
        let (x, y) = terminal.getCursorLocation()
        guard x > 0, let line = terminal.getLine(row: y) else { return nil }
        let text = line.translateToString(trimRight: true, startCol: 0, endCol: x)
        return text.isEmpty ? nil : String(text.suffix(maxChars))
    }

    func detach() {
        task?.cancel()
        task = nil
        writer = nil
        state = .idle
    }

    // MARK: - TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let buffer = ByteBuffer(bytes: data)
        Task { @MainActor in try? await self.writer?.write(buffer) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            try? await self.writer?.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor in self.onTitle?(title) }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { Task { @MainActor in UIApplication.shared.open(url) } }
    }
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { Task { @MainActor in UIPasteboard.general.string = s } }
    }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// SwiftTerm's view, with swipes that scroll tmux instead of selecting in it.
///
/// With `mouse on`, tmux asks for mouse reports, and SwiftTerm then turns a finger
/// drag into a held button plus motion: tmux reads that as a drag-select. Here a
/// vertical swipe (or a trackpad's two-finger scroll) becomes wheel events instead,
/// which tmux turns into copy-mode scrolling, with momentum after the finger lifts.
/// Long-press still selects text, as before.
final class PadTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private var scrollPan: UIPanGestureRecognizer!
    /// Finger travel not yet turned into wheel steps (points).
    private var pending: CGFloat = 0
    private var lastTranslation: CGFloat = 0
    private var momentum: CADisplayLink?
    private var velocity: CGFloat = 0
    private var touchPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrollPanned(_:)))
        scrollPan.allowedScrollTypesMask = .all
        scrollPan.maximumNumberOfTouches = 1
        scrollPan.delegate = self
        addGestureRecognizer(scrollPan)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Don't install SwiftTerm's drag-as-mouse gesture; scrolling is handled here.
    override func mouseModeChanged(source: Terminal) {}

    /// tmux scrolls 5 lines per wheel step; one step per 2.5 rows of finger travel
    /// scrolls twice as fast as the finger, which reads better through long output.
    private var stepHeight: CGFloat { font.lineHeight * 2.5 }

    @objc private func scrollPanned(_ g: UIPanGestureRecognizer) {
        let mouse = getTerminal().mouseMode != .off
        switch g.state {
        case .began:
            stopMomentum()
            lastTranslation = 0
            pending = 0
            touchPoint = g.location(in: self)
        case .changed:
            guard mouse else { return }
            let t = g.translation(in: self).y
            consume(t - lastTranslation)
            lastTranslation = t
        case .ended:
            guard mouse else { return }
            velocity = g.velocity(in: self).y
            if abs(velocity) > 200 { startMomentum() }
        default:
            break
        }
    }

    private func consume(_ dy: CGFloat) {
        pending += dy
        while abs(pending) >= stepHeight {
            let up = pending > 0   // finger down = back in history = wheel up
            sendWheel(up: up)
            pending -= up ? stepHeight : -stepHeight
        }
    }

    private func sendWheel(up: Bool) {
        let t = getTerminal()
        let cellW = max(1, ("W" as NSString).size(withAttributes: [.font: font]).width)
        let col = min(max(0, Int(touchPoint.x / cellW)), t.cols - 1)
        let row = min(max(0, Int((touchPoint.y - contentOffset.y) / font.lineHeight)), t.rows - 1)
        let flags = t.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
        t.sendEvent(buttonFlags: flags, x: col, y: row)
    }

    private func startMomentum() {
        let link = CADisplayLink(target: self, selector: #selector(momentumTick(_:)))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        consume(velocity * dt)
        velocity *= 0.94
        if abs(velocity) < 60 { stopMomentum() }
    }

    private func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }

    // Run alongside SwiftTerm's taps and long-press; only one-finger vertical drags start here.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other is UILongPressGestureRecognizer || other is UITapGestureRecognizer
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === scrollPan else { return super.gestureRecognizerShouldBegin(g) }
        let v = scrollPan.velocity(in: self)
        return abs(v.y) > abs(v.x)
    }
}
