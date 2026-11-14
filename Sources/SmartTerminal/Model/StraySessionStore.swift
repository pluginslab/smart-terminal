import Foundation
import Observation
import SmartTerminalCore

/// The Stray entry's sessions: tmux sessions on supermaschine no tab here has taken in.
/// Refreshed by whoever shows it (the columns layout polls while on screen), off the
/// main thread; a host that can't be reached just lists nothing.
@MainActor
@Observable
final class StraySessionStore {
    private(set) var sessions: [RemoteTmuxSession] = []
    /// The last listing failed (no network, Tailscale down, the key not there).
    private(set) var unreachable = false
    @ObservationIgnored private var ledger: StrayLedger
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastAsked = Date.distantPast

    /// `stray-sessions.json` next to the layout, so dev builds keep their own.
    init(url: URL = LayoutStore.default().url.deletingLastPathComponent().appendingPathComponent("stray-sessions.json")) {
        self.url = url
        ledger = StrayLedger.load(from: url) ?? StrayLedger()
    }

    /// Lists the host's sessions again. Every window's columns poll, so calls closer
    /// together than `minInterval` are dropped unless `force`d (the Stray entry was picked).
    func refresh(adoptedByTabs: @escaping @MainActor () -> Set<String>, force: Bool = false) {
        guard !inFlight, force || Date().timeIntervalSince(lastAsked) > 8, let ssh = Shell.which("ssh") else { return }
        inFlight = true
        lastAsked = Date()
        let args = StraySessions.listArguments(controlPath: Self.controlPath())
        Shell.queue.async {
            let listed = Shell.run(ssh, args, timeout: 10).map(RemoteTmuxSession.parse)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.received(listed, adoptedByTabs: adoptedByTabs()) }
            }
        }
    }

    private func received(_ listed: [RemoteTmuxSession]?, adoptedByTabs: Set<String>) {
        inFlight = false
        // A failed listing (or no tmux server at all: list-sessions exits 1) says
        // nothing about what is adopted; the ledger waits for one that came through.
        guard let listed else {
            if !sessions.isEmpty { sessions = [] }
            if !unreachable { unreachable = true }
            return
        }
        if unreachable { unreachable = false }
        let before = ledger
        let strays = ledger.reconcile(listed: listed, adoptedByTabs: adoptedByTabs)
        if ledger != before { save() }
        if strays != sessions { sessions = strays }
    }

    /// Taken in (kept in Ungrouped, or its tab put in a group): it stops being stray
    /// at once, not at the next listing.
    func adopt(_ names: Set<String>) {
        guard ledger.adopt(names) else { return }
        save()
        if sessions.contains(where: { names.contains($0.name) }) { sessions.removeAll { names.contains($0.name) } }
    }

    func isStray(_ name: String) -> Bool { sessions.contains { $0.name == name } }

    private func save() { try? ledger.save(to: url) }

    /// The shared connection's socket. Under 104 bytes (the limit for a socket's
    /// path), and its folder must exist before ssh can create it.
    private nonisolated static func controlPath() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/cm").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir + "/smartterminal-%C"
    }
}
