import UIKit
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

/// One tab's terminal: a SwiftTerm view fed by an SSH PTY that runs
/// `tmux attach -t =<session>` on the host. Kept alive while the app runs, so
/// switching tabs keeps scrollback and doesn't re-attach.
@MainActor
final class TerminalPane: NSObject, TerminalViewDelegate {
    enum State: Equatable { case idle, attaching, attached, ended }

    let session: String
    /// The name tmux knows it by on its host (the app's name less the host's prefix).
    let tmuxName: String
    let view: TerminalView

    /// Raise the keyboard (the only way it comes up; see PadTerminalView).
    func focus() {
        if let v = view as? PadTerminalView { v.focus() } else { _ = view.becomeFirstResponder() }
    }
    private(set) var state: State = .idle { didSet { onState?(state) } }
    var onState: ((State) -> Void)?
    var onTitle: ((String) -> Void)?

    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?

    init(session: String, tmuxName: String? = nil) {
        self.session = session
        self.tmuxName = tmuxName ?? session
        view = PadTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.terminalDelegate = self
        Theme.apply(to: view)
        // A pinch in another pane changed the size: follow it.
        fontObserver = NotificationCenter.default.addObserver(forName: Theme.fontSizeChanged, object: nil,
                                                              queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as AnyObject? !== self.view else { return }
                Theme.setFont(self.view, size: Theme.fontSize)
            }
        }
    }

    private var fontObserver: NSObjectProtocol?

    /// Attaches over `client` unless already attached.
    func attach(using client: SSHClient) {
        guard state != .attaching, state != .attached else { return }
        state = .attaching
        let term = view.getTerminal()
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: max(term.cols, 20), terminalRowHeight: max(term.rows, 5),
            terminalPixelWidth: pixels(cols: term.cols, rows: term.rows).width,
            terminalPixelHeight: pixels(cols: term.cols, rows: term.rows).height,
            terminalModes: SSHTerminalModes([:]))
        let name = tmuxName
        task = Task { [weak self] in
            do {
                try await client.withPTY(request) { inbound, outbound in
                    let size = await MainActor.run { () -> (Int, Int, Int, Int)? in
                        self?.writer = outbound
                        self?.state = .attached
                        guard let self else { return nil }
                        let t = self.view.getTerminal()
                        let px = self.pixels(cols: t.cols, rows: t.rows)
                        return (t.cols, t.rows, px.width, px.height)
                    }
                    // The PTY was asked for with the size the view had before layout;
                    // resizes in between found no channel yet. Send the real size now,
                    // or tmux draws wider than the view (lines off the edge, status
                    // bar wrapped onto two lines).
                    if let (cols, rows, w, h) = size {
                        try? await outbound.changeSize(cols: cols, rows: rows, pixelWidth: w, pixelHeight: h)
                    }
                    // The PTY starts a login shell; hand it over to tmux straight away.
                    // Attach only, never create: a session closed elsewhere would come back
                    // as a new (stray) one when this pane reconnects. New sessions are made
                    // before they're opened (Host.newSession).
                    try await outbound.write(ByteBuffer(string: "exec tmux attach-session -t \(Host.quote("=" + name))\n"))
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

    /// The screen's last lines up to the cursor's, for the command assist's context
    /// (tmux's status line is below the cursor, so it's left out).
    func screenText(lines: Int) -> String {
        let terminal = view.getTerminal()
        let y = terminal.getCursorLocation().y
        return (max(0, y - lines + 1)...max(0, y)).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
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
        Task { @MainActor in
            // SwiftTerm applies a latched ctrl to the next key and drops it: so does the key bar.
            if CtrlLatch.shared.on, !source.controlModifier { CtrlLatch.shared.on = false }
            try? await self.writer?.write(buffer)
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            let px = self.pixels(cols: newCols, rows: newRows)
            try? await self.writer?.changeSize(cols: newCols, rows: newRows, pixelWidth: px.width, pixelHeight: px.height)
        }
    }

    /// The text area in pixels, sent with every size. With 0 there, tmux (3.5+) asks the
    /// terminal itself (CSI 18t and 14t); the answers come back over the network, and
    /// when one arrives in pieces after tmux's short escape-time, the rest ends up typed
    /// into the pane (";30;64t" after a resize or the keyboard going away).
    private func pixels(cols: Int, rows: Int) -> (width: Int, height: Int) {
        let cell = view.cellSizeInPixels(source: view.getTerminal()) ?? (width: 10, height: 20)
        return (max(1, cell.width * cols), max(1, cell.height * rows))
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
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        // No SwiftTerm key row on the keyboard: the app's key bar stays up there instead.
        inputAccessoryView = nil
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    // MARK: - Pinch to zoom

    private var pinchStart: CGFloat = 15
    private var shownSize: CGFloat = 15

    /// Pinch changes the font size, in whole points between Theme.fontSizes, live
    /// (tmux gets the new columns and rows at each step). Every pane follows at the end.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            stopMomentum()
            pinchStart = Theme.fontSize
            shownSize = pinchStart
        case .changed:
            let wanted = (pinchStart * g.scale).rounded()
            let size = min(max(wanted, Theme.fontSizes.lowerBound), Theme.fontSizes.upperBound)
            guard size != shownSize else { return }
            shownSize = size
            Theme.setFont(self, size: size)
            let atLimit = size == Theme.fontSizes.lowerBound || size == Theme.fontSizes.upperBound
            UIImpactFeedbackGenerator(style: atLimit ? .medium : .light).impactOccurred(intensity: atLimit ? 1 : 0.5)
        case .ended, .cancelled:
            guard shownSize != Theme.fontSize else { return }
            Theme.fontSize = shownSize
            NotificationCenter.default.post(name: Theme.fontSizeChanged, object: self)
        default:
            break
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Only asked-for focus raises the keyboard: the key bar's keyboard button, a
    /// session picked with a hardware keyboard (DetailColumn) and a long-press (for
    /// the copy/paste menu). A tap doesn't (SwiftTerm focuses on tap), and neither does
    /// UIKit putting focus back after an alert or a sheet or on returning to the front.
    func focus() {
        focusAllowed = true
        _ = becomeFirstResponder()
        focusAllowed = false
    }
    private var focusAllowed = false

    override func becomeFirstResponder() -> Bool {
        let longPress = gestureRecognizers?.contains {
            $0 is UILongPressGestureRecognizer && $0.state == .began
        } == true
        guard isFirstResponder || focusAllowed || longPress else { return false }
        return super.becomeFirstResponder()
    }

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
        if g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer { return false }
        return other is UILongPressGestureRecognizer || other is UITapGestureRecognizer
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === scrollPan else { return super.gestureRecognizerShouldBegin(g) }
        let v = scrollPan.velocity(in: self)
        return abs(v.y) > abs(v.x)
    }
}
