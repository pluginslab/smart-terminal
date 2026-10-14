import Foundation
import SmartTerminalCore

/// Asks tmux which pane the client running in a tab is showing, so Claude inside
/// tmux is followed like Claude in the tab itself. At most one
/// `tmux display-message` a second, off the main thread; `onAnswer` fires when
/// the pane changes.
@MainActor
final class TmuxProbe {
    private(set) var pane: TmuxPane?
    /// `-L`/`-S` from the client's command line, so a non-default server is asked.
    private(set) var socketArgs: [String] = []
    private var clientPID: pid_t = 0
    private var inFlight = false
    private var lastAsked = Date.distantPast
    var onAnswer: (() -> Void)?

    func refresh(clientPID: pid_t, clientTTY: String) {
        if clientPID != self.clientPID {
            reset()
            self.clientPID = clientPID
            socketArgs = TmuxSessionRef.socketArgs(fromClientArguments: ProcessInspector.arguments(of: clientPID) ?? [])
        }
        guard !inFlight, Date().timeIntervalSince(lastAsked) > 0.9, let tmux = Shell.which("tmux") else { return }
        inFlight = true
        lastAsked = Date()
        let args = socketArgs + ["display-message", "-p", "-c", clientTTY, TmuxPane.format]
        Task.detached(priority: .utility) {
            let answer = Shell.run(tmux, args).flatMap(TmuxPane.parse)
            await MainActor.run { [weak self] in self?.received(answer, from: clientPID) }
        }
    }

    private func received(_ answer: TmuxPane?, from client: pid_t) {
        inFlight = false
        // A failed query (client mid-switch) keeps the last known pane.
        guard client == clientPID, let answer, answer != pane else { return }
        pane = answer
        onAnswer?()
    }

    func reset() {
        clientPID = 0; pane = nil; socketArgs = []
    }

    /// Whether the server still has this session (exact name match).
    nonisolated static func hasSession(_ ref: TmuxSessionRef) -> Bool {
        guard let tmux = Shell.which("tmux") else { return false }
        return Shell.run(tmux, ref.socketArgs + ["has-session", "-t", "=" + ref.session]) != nil
    }
}
