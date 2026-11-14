import Foundation

/// A tmux session on the remote host, from `tmux list-sessions` there.
public struct RemoteTmuxSession: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    /// When something last happened in it.
    public var activity: Date
    /// How many clients are attached right now (the iPad, cc-super in Terminal.app…).
    public var attached: Int
    /// The folder of its active pane, as the host spells it.
    public var path: String

    public var id: String { name }

    public init(name: String, activity: Date, attached: Int, path: String) {
        self.name = name; self.activity = activity; self.attached = attached; self.path = path
    }

    /// Fields for `list-sessions -F`, tab-separated, parsed by `parse`. The name goes
    /// last so one with a tab in it still comes through whole.
    public static let format = "#{session_activity}\t#{session_attached}\t#{pane_current_path}\t#{session_name}"

    public static func parse(_ output: String) -> [RemoteTmuxSession] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, !f[3].isEmpty, let stamp = TimeInterval(f[0]) else { return nil }
            return RemoteTmuxSession(name: f[3], activity: Date(timeIntervalSince1970: stamp),
                                     attached: Int(f[1]) ?? 0, path: f[2])
        }
    }

    /// The folder with the home directory as `~` (`/home/pluginslab/codeable` → `~/codeable`).
    public var displayPath: String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "home" || parts[1] == "Users", !parts[2].isEmpty
        else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }
}

/// tmux sessions on supermaschine this app never opened: started by cc-super in
/// another terminal, a script, or the iPad and Android apps. They show in the
/// sidebar's Stray entry until a tab attaches to one.
public enum StraySessions {
    /// The host whose sessions are watched.
    public static let host = "supermaschine"

    /// Whether an ssh destination is that host: its tailnet name, a FQDN of it, or
    /// cc-super's `supermaschine-lan` fallback.
    public static func isHost(_ destination: String?) -> Bool {
        guard let d = destination?.split(separator: ".").first.map(String.init) else { return false }
        return d == host || d == host + "-lan"
    }

    /// The host's sessions that tabs in a group are attached to (`live`, the ssh client
    /// in front now) or would reconnect to: putting a tab in a group takes its session
    /// in. An ungrouped tab doesn't.
    public static func groupedSessions(_ tabs: [TerminalTab], live: [UUID: RemoteSessionRef]) -> Set<String> {
        Set(tabs.filter { $0.groupID != nil }.flatMap { sessions(of: $0, live: live) })
    }

    /// The host's session names a tab refers to, live or saved.
    public static func sessions(of tab: TerminalTab, live: [UUID: RemoteSessionRef]) -> [String] {
        [live[tab.id], tab.remoteSession].compactMap { $0 }
            .filter { isHost($0.host) }.compactMap(\.session)
    }

    /// Arguments for `ssh` that list the host's sessions. Never prompts (BatchMode) or
    /// hangs on a dead network (ConnectTimeout). The connection is shared and kept for
    /// a while (`controlPath`): the key is a YubiKey, which signs for one ssh at a time,
    /// so a poll that connected afresh every few seconds could collide with yours.
    public static func listArguments(controlPath: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=10m",
         host, "tmux list-sessions -F \(AgentSessionRef.shellQuote(RemoteTmuxSession.format))"]
    }

    /// What a tab runs to attach to `name`: cc-super's own command (`tmux new-session -A`
    /// over `ssh -t`), so the tab is a remote tab like any cc-super one and Reconnect
    /// works after a restart. Without cc-super's port forwards: a second ssh holding
    /// the same local ports only gets warnings.
    public static func attachRef(_ name: String) -> RemoteSessionRef {
        RemoteSessionRef(arguments: [
            "ssh", host, "-t",
            "tmux new-session -A -s \(AgentSessionRef.shellQuote(name)) 'cd ~/codeable && claude --dangerously-skip-permissions'",
        ])
    }
}

/// The sessions this app has taken in, persisted: there before it started watching,
/// moved into a group in a tab, or kept in Ungrouped on purpose. Merely opening a
/// stray in a tab doesn't take it in; it stays under Stray until one of those.
public struct StrayLedger: Codable, Equatable, Sendable {
    /// Set by the first listing that came through: everything on the host then counts
    /// as already in use, so the Stray entry doesn't fill up with it on day one.
    public var migrated: Bool
    public var adopted: Set<String>

    public init(migrated: Bool = false, adopted: Set<String> = []) {
        self.migrated = migrated; self.adopted = adopted
    }

    /// Takes in a listing: on the first one every session is adopted; after that, the
    /// ones `adoptedByTabs` (see `groupedSessions`) are. Names gone from the host are
    /// forgotten, so the set doesn't grow forever and a new session that reuses a name
    /// counts as new. Returns the strays, most recently active first.
    public mutating func reconcile(listed: [RemoteTmuxSession], adoptedByTabs: Set<String>) -> [RemoteTmuxSession] {
        let names = Set(listed.map(\.name))
        if !migrated {
            adopted.formUnion(names)
            migrated = true
        }
        adopted = adopted.intersection(names).union(adoptedByTabs.intersection(names))
        return listed.filter { !adopted.contains($0.name) }.sorted { $0.activity > $1.activity }
    }

    /// Adds names; whether any was new.
    @discardableResult
    public mutating func adopt(_ names: Set<String>) -> Bool {
        let before = adopted.count
        adopted.formUnion(names)
        return adopted.count != before
    }

    public static func load(from url: URL) -> StrayLedger? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(StrayLedger.self, from: $0) }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
