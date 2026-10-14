import Foundation

/// The pane a tmux client is showing, from `tmux display-message -p -c <client tty>`.
public struct TmuxPane: Equatable, Sendable {
    public var session: String
    public var paneID: String
    /// The pane's own process (usually a shell, or `zsh -c …` for a command pane).
    public var panePID: Int32
    /// What the program in the pane set as its title (Claude's "✳ Fix the bug").
    public var title: String

    public init(session: String, paneID: String, panePID: Int32, title: String) {
        self.session = session; self.paneID = paneID; self.panePID = panePID; self.title = title
    }

    /// Fields for `display-message -p`, tab-separated; parsed by `parse`.
    public static let format = "#{session_name}\t#{pane_id}\t#{pane_pid}\t#{pane_title}"

    public static func parse(_ output: String) -> TmuxPane? {
        let line = output.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3, !f[0].isEmpty, let pid = Int32(f[2]), pid > 0 else { return nil }
        return TmuxPane(session: f[0], paneID: f[1], panePID: pid, title: f.count > 3 ? f[3] : "")
    }
}

/// A tmux session a tab was attached to, persisted with the layout so the tab can
/// get back into it after the app restarts (re-attach if the server still has it,
/// otherwise recreate it and resume the Claude session that ran inside).
public struct TmuxSessionRef: Codable, Hashable, Sendable {
    public var session: String
    /// `-L name` or `-S path` from the client's command line; empty for the default server.
    public var socketArgs: [String]

    public init(session: String, socketArgs: [String] = []) {
        self.session = session; self.socketArgs = socketArgs
    }

    /// The server-selecting options of a tmux client's argv
    /// (`tmux -L work attach -t x` → `["-L", "work"]`).
    public static func socketArgs(fromClientArguments args: [String]) -> [String] {
        var out: [String] = []
        var i = 1 // argv[0] is tmux itself
        while i < args.count {
            let a = args[i]
            if a == "-L" || a == "-S", i + 1 < args.count {
                out += [a, args[i + 1]]; i += 2; continue
            }
            if (a.hasPrefix("-L") || a.hasPrefix("-S")), a.count > 2 {
                out += [String(a.prefix(2)), String(a.dropFirst(2))]
            }
            // Global options stop at the command (attach, new-session, …).
            if !a.hasPrefix("-") { break }
            i += 1
        }
        return out
    }

    private var tmux: String { (["tmux"] + socketArgs).map(AgentSessionRef.shellQuote).joined(separator: " ") }
    private var target: String { AgentSessionRef.shellQuote(session) }

    /// Shell command that attaches this tab to the still-running session.
    public var attachCommand: String { "\(tmux) attach -t \(target)" }

    /// Shell command that recreates the session in `cwd`, starts `command` in it
    /// (typed into its shell, so the pane survives the command exiting) and attaches.
    public func recreateCommand(cwd: String?, command: String?) -> String {
        var new = "\(tmux) new-session -d -s \(target)"
        if let cwd, !cwd.isEmpty { new += " -c \(AgentSessionRef.shellQuote(cwd))" }
        var parts = [new]
        if let command { parts.append("\(tmux) send-keys -t \(target) \(AgentSessionRef.shellQuote(command)) Enter") }
        parts.append(attachCommand)
        return parts.joined(separator: " && ")
    }
}

/// What a tab can offer to get back to after a restart.
public enum TabRecovery: Equatable, Sendable {
    /// Claude ran directly in the tab: `claude --resume`.
    case resume(AgentSessionRef)
    /// The tab was attached to a tmux session that is still running (Claude inside, if any, never stopped).
    case reattach(TmuxSessionRef, agent: AgentSessionRef?)
    /// The tab's tmux session is gone (e.g. after a reboot): recreate it and resume Claude inside.
    case recreate(TmuxSessionRef, agent: AgentSessionRef?)

    public var agent: AgentSessionRef? {
        switch self {
        case .resume(let a): a
        case .reattach(_, let a), .recreate(_, let a): a
        }
    }

    /// The line typed into the tab's shell.
    public func command(cwd: String?) -> String {
        switch self {
        case .resume(let a): a.resumeCommand
        case .reattach(let t, _): t.attachCommand
        case .recreate(let t, let a): t.recreateCommand(cwd: a?.cwd ?? cwd, command: a?.resumeCommand)
        }
    }

    /// Picks the offer for a tab's saved references. `tmuxAlive` asks the tmux server.
    public static func make(agent: AgentSessionRef?, tmux: TmuxSessionRef?, tmuxAlive: (TmuxSessionRef) -> Bool) -> TabRecovery? {
        if let tmux { return tmuxAlive(tmux) ? .reattach(tmux, agent: agent) : .recreate(tmux, agent: agent) }
        return agent.map { .resume($0) }
    }
}
