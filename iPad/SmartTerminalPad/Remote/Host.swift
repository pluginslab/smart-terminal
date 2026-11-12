import Foundation
import Observation
import Citadel
import NIOCore
import SmartTerminalCore

/// A tmux session on the host: one tab in the iPad app.
struct RemoteSession: Identifiable, Hashable {
    var id: String { name }
    var name: String
    /// The active pane's folder, command and title.
    var path: String
    var command: String
    var title: String
    var panePID: Int32
    var lastActivity: Date
    var attachedClients: Int
    /// Claude in this pane, from its title and ~/.claude/sessions.
    var agent: AgentStatus?
    var agentName: String?
}

/// One SSH connection to a host and what its tmux has, refreshed every few seconds.
@MainActor @Observable
final class Host {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    let address: String
    let user: String
    private(set) var state: State = .idle
    private(set) var sessions: [RemoteSession] = []
    private(set) var git: [String: GitStatus] = [:]
    private(set) var client: SSHClient?
    private var poller: Task<Void, Never>?
    private var gitTick = 0

    init(address: String, user: String) {
        self.address = address
        self.user = user
    }

    var displayName: String { String(address.split(separator: ".").first ?? Substring(address)) }

    func connect() {
        guard state != .connecting else { return }
        if let client, client.isConnected { return }
        state = .connecting
        Task {
            do {
                let c = try await SSHClient.connect(
                    host: address,
                    authenticationMethod: .ed25519(username: user, privateKey: DeviceKey.privateKey),
                    hostKeyValidator: .custom(PinnedHostKey(host: address)),
                    reconnect: .never,
                    connectTimeout: .seconds(10))
                c.onDisconnect { [weak self] in
                    Task { @MainActor in self?.dropped() }
                }
                client = c
                state = .connected
                startPolling()
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    /// iPadOS cuts the socket soon after the app leaves the screen; come back with a new one.
    func reconnectIfNeeded() {
        if client?.isConnected != true { client = nil; connect() }
    }

    private func dropped() {
        client = nil
        poller?.cancel()
        if state == .connected { state = .idle }
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Commands

    /// Output of a command, or nil when it failed.
    func run(_ command: String) async -> String? {
        guard let client else { return nil }
        guard let buf = try? await client.executeCommand(command, mergeStreams: false) else { return nil }
        return String(buffer: buf)
    }

    func newSession(named name: String, in folder: String? = nil) async {
        let dir = folder.map { " -c \(Self.quote($0))" } ?? ""
        _ = await run("tmux new-session -d -s \(Self.quote(name))\(dir)")
        await refresh()
    }

    func kill(_ session: String) async {
        _ = await run("tmux kill-session -t \(Self.quote("=" + session))")
        await refresh()
    }

    func rename(_ session: String, to name: String) async {
        _ = await run("tmux rename-session -t \(Self.quote("=" + session)) \(Self.quote(name))")
        await refresh()
    }

    // MARK: - Status

    private static let sep = "@@ST@@"

    /// One round trip: the front pane of every session, the process tree (to find
    /// Claude under a pane's shell) and Claude's session files.
    private static let statusScript = """
    tmux list-panes -a -F '#{session_name}\t#{window_active}\t#{pane_active}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_pid}\t#{session_activity}\t#{session_attached}\t#{pane_title}' 2>/dev/null
    echo '\(sep)'
    ps -eo pid=,ppid=
    echo '\(sep)'
    for f in "$HOME"/.claude/sessions/*.json; do [ -f "$f" ] && cat "$f" && echo; done
    true
    """

    func refresh() async {
        guard let out = await run("sh -c " + Self.quote(Self.statusScript)) else { return }
        let parts = out.components(separatedBy: Self.sep + "\n")
        guard parts.count == 3 else { return }
        let parents = Self.parseParents(parts[1])
        let claude = parts[2].split(separator: "\n").compactMap {
            try? JSONDecoder().decode(ClaudeSessionRecord.self, from: Data($0.utf8))
        }
        var list: [RemoteSession] = []
        for line in parts[0].split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, f[1] == "1", f[2] == "1", let pid = Int32(f[5]) else { continue }
            let title = f.count > 8 ? f[8] : ""
            var s = RemoteSession(name: f[0], path: f[3], command: f[4], title: title, panePID: pid,
                                  lastActivity: Date(timeIntervalSince1970: Double(f[6]) ?? 0),
                                  attachedClients: Int(f[7]) ?? 0)
            let record = claude.first { Self.isDescendant($0.pid, of: pid, parents: parents) }
            if let parsed = ClaudeTitle.parse(title) {
                s.agent = parsed.status
                s.title = parsed.title
            }
            if let record, !record.isStale(now: .now), let st = record.agentStatus {
                // The file alone knows when a dialog is waiting for an answer.
                s.agent = st == .waiting || s.agent == nil ? st : s.agent
                s.agentName = record.meaningfulName
            }
            list.append(s)
        }
        sessions = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        gitTick += 1
        if gitTick % 3 == 1 { await refreshGit() }
    }

    private func refreshGit() async {
        let paths = Set(sessions.map(\.path)).sorted()
        guard !paths.isEmpty else { return }
        let script = "export GIT_OPTIONAL_LOCKS=0\n" + paths.map { p in
            let q = Self.quote(p)
            return """
            echo '\(Self.sep)'; echo \(q)
            if git -C \(q) status --porcelain=v2 --branch 2>/dev/null; then echo '@@STAT@@'; git -C \(q) diff --shortstat HEAD 2>/dev/null; fi
            """
        }.joined(separator: "\n") + "\ntrue"
        guard let out = await run("sh -c " + Self.quote(script)) else { return }
        var result: [String: GitStatus] = [:]
        for chunk in out.components(separatedBy: Self.sep + "\n").dropFirst() {
            let lines = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard lines.count == 2, chunk.contains("@@STAT@@") else { continue }
            let body = lines[1].components(separatedBy: "@@STAT@@\n")
            var status = GitStatus.parse(porcelainV2: body[0])
            if body.count > 1 { (status.insertions, status.deletions) = GitStatus.parse(shortstat: body[1]) }
            result[String(lines[0])] = status
        }
        git = result
    }

    private static func parseParents(_ ps: String) -> [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        for line in ps.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count == 2, let p = Int32(f[0]), let pp = Int32(f[1]) { map[p] = pp }
        }
        return map
    }

    private static func isDescendant(_ pid: Int32, of root: Int32, parents: [Int32: Int32]) -> Bool {
        var p = pid
        for _ in 0..<12 {
            if p == root { return true }
            guard let next = parents[p], next > 1 else { return false }
            p = next
        }
        return false
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        let text = String(describing: error)
        if text.contains("allAuthenticationOptionsFailed") || text.contains("authentication") {
            return "The host refused this iPad's key. Add it to ~/.ssh/authorized_keys."
        }
        return text
    }
}
