import Foundation
import SwiftUI
import Observation
import SmartTerminalCore

/// What the left column has selected; the middle column lists its sessions.
enum TabCategory: Hashable {
    /// `stray`: tmux sessions on the host this device hasn't taken up yet.
    case all, ungrouped, group(UUID), stray
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
    /// Sessions this device has taken up: made here, opened here, or put in a group.
    /// The rest (cc-super, scripts, other devices) wait under Stray. Nil until the
    /// first list from the host: then everything already there counts as taken up,
    /// so the lists don't change under you when this arrives.
    private var adopted: Set<String>?

    var category: TabCategory = .all
    var selected: String?
    var renaming: String?
    /// Which list columns show; RootView switches it with the orientation.
    var columns: NavigationSplitViewVisibility = .all
    var portrait = false
    /// Landscape with the lists put away, as in portrait: they come back laid over
    /// the terminal and go again when you pick a session. Pin puts them back beside it.
    var listsHidden = false
    /// iPhone (compact width): the columns are one stack, and this is the one on top.
    var compactColumn: NavigationSplitViewColumn = .sidebar
    /// Compact width (iPhone): RootView sets it from its size class.
    var compact = false

    /// Picks a category; on iPhone it also goes on to its sessions.
    func show(_ c: TabCategory) {
        category = c
        compactColumn = .content
    }

    /// Picks a session; on iPhone it also goes on to its terminal.
    /// Opening a stray session doesn't take it up: it stays under Stray until it's
    /// moved to a group (or to Ungrouped), as each device groups sessions its own way.
    func open(_ session: String) {
        selected = session
        compactColumn = .detail
    }
    /// Landscape's own choice (groups shown or not), kept while the lists are away.
    var landscapeColumns: NavigationSplitViewVisibility = .all

    /// The lists sit over the terminal rather than beside it.
    var overlaid: Bool { portrait || listsHidden }

    func hideLists() {
        if columns != .detailOnly { landscapeColumns = columns }
        listsHidden = true
        columns = .detailOnly
    }

    /// Keeps what's laid over now (sessions only, unless you opened the groups too).
    func pinLists() {
        listsHidden = false
        if columns == .detailOnly { columns = landscapeColumns } else { landscapeColumns = columns }
    }

    private var panes: [String: TerminalPane] = [:]
    let dictation = Dictation()

    init() { load() }

    // MARK: - Sessions

    var sessions: [RemoteSession] { host.sessions }

    func sessions(in c: TabCategory) -> [RemoteSession] {
        sessions.filter { s in
            let mine = isAdopted(s.name)
            switch c {
            case .all: return mine
            case .ungrouped: return mine && membership[s.name] == nil
            case .group(let g): return mine && membership[s.name] == g
            case .stray: return !mine
            }
        }
    }

    func isAdopted(_ name: String) -> Bool {
        adopted.map { $0.contains(name) } ?? true || membership[name] != nil
    }

    private func adopt(_ name: String) {
        guard adopted?.contains(name) == false else { return }
        adopted?.insert(name)
        save()
    }

    /// After each list from the host: the first one takes up everything there; later
    /// ones forget sessions that are gone, so a new one under an old name starts stray.
    /// An empty list is skipped: it's what there is before the first answer from the
    /// host, and taking it at its word forgot every session at each launch.
    func reconcile(_ names: [String]) {
        let now = Set(names)
        guard !now.isEmpty else { return }
        if adopted == nil {
            adopted = now
        } else {
            let kept = adopted!.intersection(now)
            guard kept != adopted else { return }
            adopted = kept
        }
        save()
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

    /// Dictate into a session: see `Dictation`.
    /// A plain shell (no Claude in the pane): the mic makes commands, not words.
    func voiceCommands(in session: String) -> Bool {
        sessions.first { $0.name == session }
            .map { $0.agent == nil && ["zsh", "bash", "sh", "fish"].contains($0.command) } ?? false
    }

    func dictate(_ session: String) {
        let path = sessions.first { $0.name == session }?.path
        dictation.toggle(host: host, pane: pane(for: session), commandIn: voiceCommands(in: session) ? path : nil)
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
        adopt(name)
        if case .group(let g) = category { membership[name] = g; save() }
        if category == .stray { category = .ungrouped }
        Task {
            await host.newSession(named: name)
            open(name)
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
        if let session { adopt(session); membership[session] = g.id }
        category = .group(g.id)
        save()
    }

    /// Moving takes a stray session up, to Ungrouped too.
    func move(_ session: String, to group: UUID?) {
        adopt(session)
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
        var adopted: [String]?
    }

    private static let key = "padLayout"

    private func save() {
        let s = Saved(groups: groups, membership: membership, customTitles: customTitles,
                      adopted: adopted.map { $0.sorted() })
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.key)
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        groups = s.groups
        membership = s.membership
        customTitles = s.customTitles
        adopted = s.adopted.map(Set.init)
    }
}
