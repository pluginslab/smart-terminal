import Foundation
import SwiftUI
import UIKit
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
    /// The Linux running in iSH+ on this device, over SSH to its forwarded port.
    let ish = Host(address: "127.0.0.1", user: UserDefaults.standard.string(forKey: PadModel.ishUserKey) ?? "",
                   ports: PadModel.ishPorts, isLocal: true)
    static let ishUserKey = "ishUser"
    static let ishPortKey = "ishPort"
    /// The port set in the sheet first, then where iSH+ usually forwards sshd.
    static var ishPorts: [Int] {
        let set = UserDefaults.standard.integer(forKey: ishPortKey)
        return ([set > 0 ? set : nil, 2222, 22, 10022, 12222].compactMap { $0 })
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var ishPort: Int { ish.ports.first ?? 2222 }

    func setIshPort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: Self.ishPortKey)
        ish.ports = Self.ishPorts
    }
    /// iSH+ is on this device (its URL scheme answers).
    private(set) var ishInstalled = false
    /// The setup sheet for iSH+ (the commands to run in it, the user name).
    var ishSetup = false
    /// Shown in an alert: a session that couldn't be made, and why.
    var problem: String?
    var ishConfigured: Bool { !ish.user.isEmpty }

    var hosts: [Host] { ishInstalled ? [host, ish] : [host] }

    /// The host a session lives on, from its name's prefix.
    func host(of session: String) -> Host {
        ishInstalled && ish.owns(session) && !ish.prefix.isEmpty ? ish : host
    }

    func refresh() async {
        for h in hosts where h.state == .connected { await h.refresh() }
    }

    func connect() {
        ishInstalled = UIApplication.shared.canOpenURL(URL(string: "ishplus://")!)
        host.connect()
        if ishInstalled, ishConfigured { ish.connect() }
        // iSH+'s Linux comes and goes (started later, switched to another distribution,
        // paused in the background): look for it again every few seconds.
        guard ishWatcher == nil else { return }
        ishWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard let self, self.ishInstalled, self.ishConfigured else { continue }
                if self.ish.state != .connected, self.ish.state != .connecting { self.ish.connect() }
            }
        }
    }
    private var ishWatcher: Task<Void, Never>?

    func setIshUser(_ user: String) {
        let u = user.trimmingCharacters(in: .whitespaces)
        ish.user = u
        UserDefaults.standard.set(u, forKey: Self.ishUserKey)
        ish.reconnectIfNeeded()
    }

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

    var sessions: [RemoteSession] { hosts.flatMap { $0.state == .connected ? $0.sessions : [] } }

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

    /// After each list from a host: the first one from supermaschine takes up everything
    /// there; later ones forget that host's sessions that are gone, so a new one under an
    /// old name starts stray. A host that hasn't answered yet (or is away, as iSH+ often
    /// is, or runs another distribution now) keeps its names.
    func reconcile() {
        if adopted == nil {
            guard host.loaded, !host.sessions.isEmpty else { return }
            adopted = Set(host.sessions.map(\.name))
            save()
            return
        }
        var kept = adopted!
        for h in hosts where h.state == .connected && h.loaded && !(h.isLocal && h.prefix.isEmpty) {
            let now = Set(h.sessions.map(\.name))
            kept = kept.filter { !h.owns($0) || now.contains($0) }
        }
        guard kept != adopted else { return }
        adopted = kept
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
        let p = TerminalPane(session: session, tmuxName: host(of: session).tmuxName(session))
        panes[session] = p
        return p
    }

    /// Dictate into a session: see `Dictation`.
    /// A plain shell (no Claude in the pane): the mic makes commands, not words.
    func voiceCommands(in session: String) -> Bool {
        sessions.first { $0.name == session }
            .map { $0.agent == nil && ["zsh", "bash", "sh", "ash", "fish"].contains($0.command) } ?? false
    }

    func dictate(_ session: String) {
        let path = sessions.first { $0.name == session }?.path
        // The dictation and assist configs are on supermaschine; the folder's context
        // comes from the pane's own host (iSH+'s Linux for its sessions).
        dictation.toggle(host: host, contextHost: host(of: session), pane: pane(for: session),
                         commandIn: voiceCommands(in: session) ? path : nil)
    }

    /// Re-attach every pane after a dropped connection (the app came back to the front).
    func resume() {
        host.reconnectIfNeeded()
        if ishInstalled, ishConfigured { ish.reconnectIfNeeded() }
        for p in panes.values where p.state == .ended { p.detach() }
    }

    /// A new session on supermaschine, or (`on: ish`) in iSH+'s Linux.
    func newSession(on target: Host? = nil) {
        let h = target ?? host
        let taken = Set(sessions.map(\.name))
        let base = UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad"
        var n = 1
        while taken.contains(h.prefix + "\(base)-\(n)") { n += 1 }
        let name = h.prefix + "\(base)-\(n)"
        adopt(name)
        if case .group(let g) = category { membership[name] = g; save() }
        if category == .stray { category = .ungrouped }
        Task {
            if let error = await h.newSession(named: name) {
                problem = "Couldn't start a session on \(h.displayName): \(error)"
            } else {
                open(name)
            }
        }
    }

    func close(_ session: String) {
        // The one in front closes: the row above it takes its place (the one below
        // for the first row), as tabs do.
        if selected == session {
            let list = sessions(in: category).map(\.name)
            if let i = list.firstIndex(of: session) {
                let rest = list.filter { $0 != session }
                selected = rest.isEmpty ? nil : rest[max(0, min(i - 1, rest.count - 1))]
            } else {
                selected = nil
            }
        }
        panes[session]?.detach()
        panes[session] = nil
        membership[session] = nil
        customTitles[session] = nil
        save()
        let h = host(of: session)
        Task { await h.kill(session) }
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
