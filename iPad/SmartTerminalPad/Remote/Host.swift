import Foundation
import UIKit
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
    var user: String
    /// Tried in order: iSH+ forwards the guest's 22 to the same port, or to 10022
    /// when iOS doesn't give it that one.
    var ports: [Int]
    /// iSH+: the Linux running in it on this device. Each distribution has its own host
    /// key, and nothing leaves the device, so its key isn't pinned.
    let isLocal: Bool
    /// Put before tmux's session names, so sessions from two hosts never share a name
    /// (tmux names can't hold ":"). Empty for supermaschine; "ish-debian:" for iSH+,
    /// so each distribution keeps its own groups.
    private(set) var prefix = ""
    /// iSH+: the running distribution's name ("Debian GNU/Linux 13").
    private(set) var distro: String?
    /// The sessions have been listed at least once since connecting.
    private(set) var loaded = false
    private(set) var state: State = .idle
    private(set) var sessions: [RemoteSession] = []
    private(set) var git: [String: GitStatus] = [:]
    private(set) var client: SSHClient?
    private var poller: Task<Void, Never>?
    private var gitTick = 0

    init(address: String, user: String, ports: [Int] = [22], isLocal: Bool = false) {
        self.address = address
        self.user = user
        self.ports = ports
        self.isLocal = isLocal
    }

    var displayName: String {
        if isLocal { return distro.map { "iSH+ · " + Self.shortDistro($0) } ?? "iSH+" }
        return String(address.split(separator: ".").first ?? Substring(address))
    }

    /// "Debian GNU/Linux 13 (trixie)" -> "Debian"
    static func shortDistro(_ name: String) -> String {
        String(name.split(separator: " ").first ?? Substring(name))
    }

    /// The tmux name of one of this host's sessions (the app's name less the prefix).
    func tmuxName(_ name: String) -> String {
        name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    func owns(_ name: String) -> Bool {
        prefix.isEmpty ? !name.contains(":") : name.hasPrefix(prefix)
    }

    func connect() {
        guard state != .connecting else { return }
        if let client, client.isConnected { return }
        state = .connecting
        Task {
            var lastError: Error?
            for port in ports {
                do {
                    let c = try await SSHClient.connect(
                        host: address, port: port,
                        authenticationMethod: .ed25519(username: user, privateKey: DeviceKey.privateKey),
                        hostKeyValidator: isLocal ? .acceptAnything() : .custom(PinnedHostKey(host: address)),
                        reconnect: .never,
                        connectTimeout: .seconds(isLocal ? 3 : 10))
                    c.onDisconnect { [weak self] in
                        Task { @MainActor in self?.dropped() }
                    }
                    client = c
                    if isLocal { await identify() }
                    state = .connected
                    startPolling()
                    return
                } catch {
                    lastError = error
                    // Refused: nothing listens there; the next port might. Any other
                    // error (the key, the user) is the answer.
                    if !Self.isRefused(error) { break }
                }
            }
            if isLocal, let e = lastError, Self.isRefused(e) {
                state = .failed("Nothing answers on 127.0.0.1 (ports \(ports.map(String.init).joined(separator: ", "))). Is Linux running in iSH+, with Keep Running in Background on and sshd listening?")
            } else {
                state = .failed(lastError.map(Self.describe) ?? "Couldn't connect")
            }
        }
    }

    /// iPadOS cuts the socket soon after the app leaves the screen; come back with a new one.
    func reconnectIfNeeded() {
        if client?.isConnected != true { client = nil; connect() }
    }

    /// iSH+: which distribution answered, for the name and the session prefix.
    private func identify() async {
        let out = await run("sh -c " + Self.quote(". /etc/os-release 2>/dev/null; echo \"$ID\"; echo \"$PRETTY_NAME\""))
        let lines = (out ?? "").split(separator: "\n").map(String.init)
        let id = lines.first.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } } ?? ""
        prefix = "ish-\(id.isEmpty ? "linux" : id):"
        distro = lines.count > 1 ? lines[1] : nil
        sessions = []
        git = [:]
        loaded = false
    }

    private static func isRefused(_ error: Error) -> Bool {
        let t = String(describing: error).lowercased()
        return t.contains("refused") || t.contains("reset") || t.contains("connectionfailure")
            || t.contains("connect(descriptor") || t.contains("timeout") || t.contains("timed out")
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
        if isLocal {
            // iSH+'s Linux pauses when iOS suspends iSH+ in the background, and its port
            // then neither answers nor closes. Don't hang on it: give up after a while,
            // call it paused, and the watcher connects again once Linux runs.
            enum Outcome: Sendable { case output(String), failed, timedOut }
            let outcome = await withTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    guard let b = try? await client.executeCommand(command, mergeStreams: false) else { return .failed }
                    return .output(String(buffer: b))
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(8))
                    return .timedOut
                }
                let first = await group.next() ?? .failed
                group.cancelAll()
                return first
            }
            switch outcome {
            case .output(let out): return out
            case .failed: return nil
            case .timedOut:
                paused(client)
                return nil
            }
        }
        guard let buf = try? await client.executeCommand(command, mergeStreams: false) else { return nil }
        return String(buffer: buf)
    }

    private func paused(_ c: SSHClient) {
        guard client === c else { return }
        client = nil
        poller?.cancel()
        state = .failed("iSH+ is paused: its Linux stops while iSH+ is in the background. Turn on Keep Running in Background in iSH+ (Settings > Linux VM), or keep it beside this app in Split View.")
        Task { try? await c.close() }
    }

    /// Nil when made; otherwise what went wrong (tmux missing, the server refusing…).
    @discardableResult
    func newSession(named name: String, in folder: String? = nil) async -> String? {
        let dir = folder.map { " -c \(Self.quote($0))" } ?? ""
        let cmd = "tmux new-session -d -s \(Self.quote(tmuxName(name)))\(dir) 2>&1; echo \"@@rc=$?\""
        let out = await run("sh -c " + Self.quote(cmd))
        await refresh()
        guard let out else { return "No connection to \(displayName)." }
        if out.contains("@@rc=0") { return nil }
        let msg = out.replacingOccurrences(of: #"@@rc=\d+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "tmux failed on \(displayName)." : msg
    }

    func kill(_ session: String) async {
        _ = await run("tmux kill-session -t \(Self.quote("=" + tmuxName(session)))")
        await refresh()
    }

    func rename(_ session: String, to name: String) async {
        _ = await run("tmux rename-session -t \(Self.quote("=" + tmuxName(session))) \(Self.quote(tmuxName(name)))")
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
            var s = RemoteSession(name: prefix + f[0], path: f[3], command: f[4], title: title, panePID: pid,
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
        loaded = true
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
            return "The host refused this \(UIDevice.current.model)'s key. Add it to ~/.ssh/authorized_keys."
        }
        return text
    }
}
