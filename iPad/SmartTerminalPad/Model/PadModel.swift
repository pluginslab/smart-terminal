import Foundation
import Observation
import SmartTerminalCore

/// What the left column has selected; the middle column lists its sessions.
enum TabCategory: Hashable {
    case all, ungrouped, group(UUID)
}

/// The iPad's own state around the host's tmux sessions: groups, names you gave
/// them, and which one is in front. Saved on the device.
@MainActor @Observable
final class PadModel {
    let host = Host(address: "supermaschine", user: "pluginslab")

    private(set) var groups: [TabGroup] = []
    /// tmux session name -> group
    private(set) var membership: [String: UUID] = [:]
    private(set) var customTitles: [String: String] = [:]

    var category: TabCategory = .all
    var selected: String?
    var renaming: String?

    private var panes: [String: TerminalPane] = [:]

    init() { load() }

    // MARK: - Sessions

    var sessions: [RemoteSession] { host.sessions }

    func sessions(in c: TabCategory) -> [RemoteSession] {
        sessions.filter { s in
            switch c {
            case .all: true
            case .ungrouped: membership[s.name] == nil
            case .group(let g): membership[s.name] == g
            }
        }
    }

    func group(of s: RemoteSession) -> TabGroup? {
        membership[s.name].flatMap { id in groups.first { $0.id == id } }
    }

    func title(of s: RemoteSession) -> String {
        if let t = customTitles[s.name], !t.isEmpty { return t }
        if let n = s.agentName { return n }
        if s.agent != nil, !s.title.isEmpty { return s.title }
        return s.name
    }

    func pane(for session: String) -> TerminalPane {
        if let p = panes[session] { return p }
        let p = TerminalPane(session: session)
        panes[session] = p
        return p
    }

    /// Re-attach every pane after a dropped connection (the app came back to the front).
    func resume() {
        host.reconnectIfNeeded()
        for p in panes.values where p.state == .ended { p.detach() }
    }

    func newSession() {
        let taken = Set(sessions.map(\.name))
        var n = 1
        while taken.contains("ipad-\(n)") { n += 1 }
        let name = "ipad-\(n)"
        if case .group(let g) = category { membership[name] = g; save() }
        Task {
            await host.newSession(named: name)
            selected = name
        }
    }

    func close(_ session: String) {
        panes[session]?.detach()
        panes[session] = nil
        membership[session] = nil
        customTitles[session] = nil
        save()
        if selected == session { selected = nil }
        Task { await host.kill(session) }
    }

    func rename(_ session: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        customTitles[session] = t.isEmpty ? nil : t
        save()
    }

    // MARK: - Groups

    func newGroup(with session: String? = nil) {
        let used = Set(groups.map(\.color))
        let color = GroupColor.allCases.first { !used.contains($0) } ?? .blue
        let g = TabGroup(name: "", color: color)
        groups.append(g)
        if let session { membership[session] = g.id }
        category = .group(g.id)
        save()
    }

    func move(_ session: String, to group: UUID?) {
        membership[session] = group
        save()
    }

    func updateGroup(_ id: UUID, name: String? = nil, color: GroupColor? = nil) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        if let name { groups[i].name = name }
        if let color { groups[i].color = color }
        save()
    }

    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        membership = membership.filter { $0.value != id }
        if category == .group(id) { category = .all }
        save()
    }

    func groupTitle(_ g: TabGroup) -> String {
        g.name.isEmpty ? "Unnamed \(g.color.displayName) Group" : g.name
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var groups: [TabGroup]
        var membership: [String: UUID]
        var customTitles: [String: String]
    }

    private static let key = "padLayout"

    private func save() {
        let s = Saved(groups: groups, membership: membership, customTitles: customTitles)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.key)
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        groups = s.groups
        membership = s.membership
        customTitles = s.customTitles
    }
}
