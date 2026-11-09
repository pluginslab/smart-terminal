import Foundation

/// The pane a tmux client is showing, from `tmux list-clients` (the row for that client's tty).
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

    /// Fields for `list-clients -F`, tab-separated, one line per client; parsed by `parse`.
    /// Not `display-message -c <tty>`: without `-t` its formats describe tmux's most
    /// recently active client, whichever tty is named, so every tab saw the same pane.
    public static let format = "#{client_tty}\t#{session_name}\t#{pane_id}\t#{pane_pid}\t#{pane_title}"

    /// The pane shown by the client on `clientTTY` (e.g. "/dev/ttys012").
    public static func parse(_ output: String, clientTTY: String) -> TmuxPane? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, f[0] == clientTTY else { continue }
            guard !f[1].isEmpty, let pid = Int32(f[3]), pid > 0 else { return nil }
            return TmuxPane(session: f[1], paneID: f[2], panePID: pid, title: f.count > 4 ? f[4] : "")
        }
        return nil
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

    /// Whether this is `session` on the server at `socketPath` (from a client's `$TMUX`).
    /// Servers are told apart by their socket's name: "default", a `-L` name, or a `-S` file.
    public func matches(socketPath: String, session other: String) -> Bool {
        guard session == other else { return false }
        let name = (socketPath as NSString).lastPathComponent
        var mine = "default"
        if let i = socketArgs.firstIndex(where: { $0 == "-L" || $0 == "-S" }), i + 1 < socketArgs.count {
            mine = socketArgs[i] == "-L" ? socketArgs[i + 1] : (socketArgs[i + 1] as NSString).lastPathComponent
        }
        return mine == name
    }

    private var tmux: String { (["tmux"] + socketArgs).map(AgentSessionRef.shellQuote).joined(separator: " ") }
    private var target: String { AgentSessionRef.shellQuote(session) }

    /// Shell command that attaches this tab to the still-running session.
    public var attachCommand: String { "\(tmux) attach -t \(target)" }

    /// Shell command that recreates the session in `cwd`, starts `command` in it
    /// (typed into its shell, so the pane survives the command exiting) and attaches.
    /// `tabID`: set as `SMART_TERMINAL_TAB` in the session. tmux otherwise gives a new
    /// session the environment of whichever tab started its server, and Claude inside
    /// would be counted as that tab's.
    public func recreateCommand(cwd: String?, command: String?, tabID: UUID? = nil) -> String {
        var new = "\(tmux) new-session -d -s \(target)"
        if let cwd, !cwd.isEmpty { new += " -c \(AgentSessionRef.shellQuote(cwd))" }
        if let tabID { new += " -e SMART_TERMINAL_TAB=\(tabID.uuidString)" }
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
    /// The tab was in ssh, attached to tmux on the other host: run the same ssh again.
    case reconnect(RemoteSessionRef)

    public var agent: AgentSessionRef? {
        switch self {
        case .resume(let a): a
        case .reattach(_, let a), .recreate(_, let a): a
        case .reconnect: nil
        }
    }

    /// The line typed into the tab's shell.
    public func command(cwd: String?, tabID: UUID? = nil) -> String {
        switch self {
        case .resume(let a): a.resumeCommand
        case .reattach(let t, _): t.attachCommand
        case .recreate(let t, let a): t.recreateCommand(cwd: a?.cwd ?? cwd, command: a?.resumeCommand, tabID: tabID)
        case .reconnect(let r): r.command
        }
    }

    /// Picks the offer for a tab's saved references. `tmuxAlive` asks the tmux server.
    public static func make(agent: AgentSessionRef?, tmux: TmuxSessionRef?, remote: RemoteSessionRef? = nil,
                            tmuxAlive: (TmuxSessionRef) -> Bool) -> TabRecovery? {
        if let remote { return .reconnect(remote) }
        if let tmux { return tmuxAlive(tmux) ? .reattach(tmux, agent: agent) : .recreate(tmux, agent: agent) }
        return agent.map { .resume($0) }
    }
}

/// An ssh client attached to tmux on another host, as `cc-super` runs it
/// (`ssh host -t "tmux new-session -A -s name …"`). Running the same command again
/// reattaches: the session, and Claude in it, went on running over there.
public struct RemoteSessionRef: Codable, Hashable, Sendable {
    /// The ssh client's argv, as it ran.
    public var arguments: [String]

    public init(arguments: [String]) { self.arguments = arguments }

    /// A reference for this ssh argv, or nil when it doesn't attach to tmux: a plain
    /// `ssh host`, or a one-off remote command, is never run again by itself.
    public static func from(sshArguments args: [String]) -> RemoteSessionRef? {
        guard let first = args.first, (first as NSString).lastPathComponent == "ssh" else { return nil }
        return attachesTmux(args.dropFirst().joined(separator: " ")) ? RemoteSessionRef(arguments: args) : nil
    }

    /// `tmux attach…`, `tmux a`, or `tmux new-session -A` / `tmux new -A` (attach if it exists).
    static func attachesTmux(_ remote: String) -> Bool {
        let words = remote.split(whereSeparator: { " \t'\"".contains($0) }).map(String.init)
        guard let t = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "tmux" }) else { return false }
        let rest = Array(words[(t + 1)...])
        // tmux's own options come before its command; -L/-S/-f take a value.
        var i = 0
        while i < rest.count, rest[i].hasPrefix("-") { i += ["-L", "-S", "-f"].contains(rest[i]) ? 2 : 1 }
        guard i < rest.count else { return false }
        let cmd = rest[i], opts = rest[(i + 1)...]
        if ["attach", "attach-session", "a", "at"].contains(cmd) { return true }
        if ["new-session", "new"].contains(cmd) {
            // A flag group with A (-A, -dA) among new-session's options, before the command it runs.
            let withValue: Set<String> = ["-c", "-e", "-F", "-f", "-n", "-s", "-t", "-x", "-y"]
            var j = opts.startIndex
            while j < opts.endIndex, opts[j].hasPrefix("-"), !opts[j].hasPrefix("--") {
                if opts[j].dropFirst().contains("A") { return true }
                j += withValue.contains(opts[j]) ? 2 : 1
            }
            return false
        }
        return false
    }

    /// The line typed into the tab's shell.
    public var command: String { arguments.map(AgentSessionRef.shellQuote).joined(separator: " ") }

    /// The host, for the Resume bar: the first argument that isn't an option or an option's value.
    public var host: String? {
        let withValue = Set("BbcDEeFIiJLlmOoPpQRSWw".map { "-\($0)" })
        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            if a.hasPrefix("-") { i += withValue.contains(a) ? 2 : 1; continue }
            return a.split(separator: "@").last.map(String.init)
        }
        return nil
    }

    /// The tmux session name (`-s name` or `-t name`), if the command gives one.
    public var session: String? {
        let words = arguments.dropFirst().joined(separator: " ")
            .split(whereSeparator: { " \t'\"".contains($0) }).map(String.init)
        guard let t = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "tmux" }) else { return nil }
        let after = words[(t + 1)...] // ssh's own -t isn't tmux's
        guard let i = after.firstIndex(where: { $0 == "-s" || $0 == "-t" }), i + 1 < words.count else { return nil }
        return words[i + 1]
    }
}
