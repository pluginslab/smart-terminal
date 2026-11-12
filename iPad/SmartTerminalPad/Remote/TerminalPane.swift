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
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
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
