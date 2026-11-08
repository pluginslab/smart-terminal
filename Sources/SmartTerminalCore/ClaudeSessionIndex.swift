import Foundation

/// `claude-sessions.json`: which Claude Code session runs (or was saved) in which tab,
/// with the tab's name and its group's name and colour, for tools outside the app
/// (the Mobile Agent bridge shows them in its sessions list).
///
/// Keyed both ways: by Claude session id, and by tab id, which a hook can name from
/// `SMART_TERMINAL_TAB` before the app has seen the session. Readers ignore a file
/// whose `pid` is gone, and fields they don't know.
public struct ClaudeSessionIndex: Codable, Equatable, Sendable {
    public static let version = 1

    public struct Group: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var color: String
        /// Its place in its window's sidebar, 0 first. The file's dictionaries carry no order.
        public var order: Int
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var tabID: String
        public var tab: String
        public var group: Group?
        public var window: Int
        public var cwd: String?
        public var sessionID: String?
        /// Its place in its window's tab list, 0 first.
        public var order: Int

        // `null`, not a missing key, for an ungrouped tab or one without a session.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tabID, forKey: .tabID)
            try c.encode(tab, forKey: .tab)
            try c.encode(group, forKey: .group)
            try c.encode(window, forKey: .window)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(order, forKey: .order)
        }
    }

    public var version: Int
    public var pid: Int32
    public var updatedAt: String
    public var sessions: [String: Tab]
    public var tabs: [String: Tab]

    /// `sessionIDs`: each tab's Claude session, running or saved.
    public init(layout: AppLayout, sessionIDs: [UUID: String], pid: Int32, now: Date = Date()) {
        version = Self.version
        self.pid = pid
        updatedAt = ISO8601DateFormatter().string(from: now)
        var sessions: [String: Tab] = [:], tabs: [String: Tab] = [:]
        for (i, w) in layout.windows.enumerated() {
            let groupOrder = w.orderedGroups.map(\.id)
            for (ti, t) in w.tabs.enumerated() {
                let group = t.groupID.flatMap { w.group($0) }.map { g in
                    Group(id: g.id.uuidString, name: g.name, color: g.color.rawValue,
                          order: groupOrder.firstIndex(of: g.id) ?? groupOrder.count)
                }
                let sid = sessionIDs[t.id]
                let entry = Tab(tabID: t.id.uuidString, tab: t.displayTitle, group: group,
                                window: i + 1, cwd: t.cwd, sessionID: sid, order: ti)
                tabs[t.id.uuidString] = entry
                if let sid { sessions[sid] = entry }
            }
        }
        self.sessions = sessions
        self.tabs = tabs
    }

    /// The same content, apart from when it was written.
    public func sameContent(as other: ClaudeSessionIndex?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return other == self
    }

    /// Replaces the file in one step (readers never see half of it), readable only by you.
    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}
