import Foundation

/// One window's tabs and groups.
///
/// Tabs are a flat ordered list; a tab belongs to a group via `groupID`.
/// Invariants (checked by `violations()`):
/// - the tabs of one group are contiguous
/// - every referenced group exists, and every group has at least one tab
/// - `activeTabID` is nil iff there are no tabs, else points at an existing tab
public struct WindowLayout: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public private(set) var tabs: [TerminalTab]
    public private(set) var groups: [UUID: TabGroup]
    public private(set) var activeTabID: UUID?
    public var frame: WindowFrame?

    public init(id: UUID = UUID(), tabs: [TerminalTab] = [], groups: [TabGroup] = [],
                activeTabID: UUID? = nil, frame: WindowFrame? = nil) {
        self.id = id
        self.tabs = tabs
        self.groups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        self.activeTabID = activeTabID ?? tabs.first?.id
        self.frame = frame
        normalize()
    }

    // Groups are stored as an array in JSON; a UUID-keyed dictionary encodes as a flat key/value list.
    private enum CodingKeys: String, CodingKey { case id, tabs, groups, activeTabID, frame }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  tabs: try c.decode([TerminalTab].self, forKey: .tabs),
                  groups: try c.decode([TabGroup].self, forKey: .groups),
                  activeTabID: try c.decodeIfPresent(UUID.self, forKey: .activeTabID),
                  frame: try c.decodeIfPresent(WindowFrame.self, forKey: .frame))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tabs, forKey: .tabs)
        try c.encode(orderedGroups, forKey: .groups)
        try c.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try c.encodeIfPresent(frame, forKey: .frame)
    }

    // MARK: - Queries

    public var isEmpty: Bool { tabs.isEmpty }
    public var activeTab: TerminalTab? { activeTabID.flatMap { tab($0) } }

    public func tab(_ id: UUID) -> TerminalTab? { tabs.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }
    public func group(_ id: UUID) -> TabGroup? { groups[id] }
    public func tabs(in groupID: UUID) -> [TerminalTab] { tabs.filter { $0.groupID == groupID } }

    /// Groups in strip order.
    public var orderedGroups: [TabGroup] {
        var seen = Set<UUID>()
        return tabs.compactMap { t in
            guard let g = t.groupID, seen.insert(g).inserted else { return nil }
            return groups[g]
        }
    }

    /// Tabs not hidden inside a collapsed group.
    public var visibleTabs: [TerminalTab] {
        tabs.filter { t in t.groupID.flatMap { groups[$0]?.isCollapsed } != true }
    }

    /// Chips and tabs in render order. Collapsed groups contribute only their chip.
    public var stripItems: [StripItem] {
        var items: [StripItem] = []
        var current: UUID?
        for t in tabs {
            if let g = t.groupID, g != current, let group = groups[g] {
                items.append(.chip(group, tabCount: tabs(in: g).count))
            }
            current = t.groupID
            if let g = t.groupID, groups[g]?.isCollapsed == true { continue }
            items.append(.tab(t))
        }
        return items
    }

    // MARK: - Tabs

    /// Adds a tab. By default it goes right after the active tab and joins the
    /// active tab's group (Terminal.app/Chrome "new tab next to me" behavior).
    @discardableResult
    public mutating func addTab(_ tab: TerminalTab = TerminalTab(), nextToActive: Bool = true, select: Bool = true) -> TerminalTab {
        var tab = tab
        if nextToActive, let active = activeTabID, let i = index(of: active) {
            tab.groupID = tabs[i].groupID
            tabs.insert(tab, at: i + 1)
        } else {
            tab.groupID = nil
            tabs.append(tab)
        }
        if select { self.select(tab.id) } else if activeTabID == nil { activeTabID = tab.id }
        normalize()
        return tab
    }

    /// Selecting a tab inside a collapsed group expands that group.
    public mutating func select(_ id: UUID) {
        guard let t = tab(id) else { return }
        activeTabID = id
        if let g = t.groupID, groups[g]?.isCollapsed == true { groups[g]?.isCollapsed = false }
    }

    /// Selects the visible tab at `offset` from the active one, wrapping.
    public mutating func selectRelative(_ offset: Int) {
        let visible = visibleTabs
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == activeTabID } ?? 0
        let n = visible.count
        select(visible[((current + offset) % n + n) % n].id)
    }

    /// ⌘1…⌘8 pick the nth visible tab; ⌘9 always picks the last.
    public mutating func selectNumber(_ number: Int) {
        let visible = visibleTabs
        guard !visible.isEmpty, number >= 1 else { return }
        let i = number == 9 ? visible.count - 1 : number - 1
        guard i < visible.count else { return }
        select(visible[i].id)
    }

    public mutating func updateTab(_ id: UUID, _ change: (inout TerminalTab) -> Void) {
        guard let i = index(of: id) else { return }
        let group = tabs[i].groupID
        change(&tabs[i])
        tabs[i].groupID = group // membership only changes through move operations
    }

    public mutating func rename(tab id: UUID, to title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateTab(id) { $0.customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    /// Removes a tab and returns it. Picks the right neighbour (else left) as new active.
    @discardableResult
    public mutating func removeTab(_ id: UUID) -> TerminalTab? {
        guard let i = index(of: id) else { return nil }
        let removed = tabs.remove(at: i)
        if activeTabID == id {
            activeTabID = nil
            let candidates = tabs.indices.filter { !isHidden(tabs[$0]) }
            if let right = candidates.first(where: { $0 >= i }) {
                activeTabID = tabs[right].id
            } else if let left = candidates.last {
                activeTabID = tabs[left].id
            } else if !tabs.isEmpty {
                select(tabs[min(i, tabs.count - 1)].id)
            }
        }
        normalize()
        return removed
    }

    public mutating func closeOthers(keeping id: UUID) -> [TerminalTab] {
        let others = tabs.filter { $0.id != id }
        others.forEach { removeTab($0.id) }
        return others
    }

    // MARK: - Moving

    /// Moves a tab within this window. No-op for targets referencing the tab itself.
    public mutating func move(tab id: UUID, to target: DropTarget) {
        if case .beforeTab(id) = target { return }
        if case .afterTab(id) = target { return }
        guard let i = index(of: id) else { return }
        let tab = tabs.remove(at: i)
        insertRaw(tab, at: target)
        normalize()
    }

    /// Inserts a tab arriving from elsewhere (another window). Keeps it selected if asked.
    public mutating func insert(_ tab: TerminalTab, at target: DropTarget, select: Bool = true) {
        insertRaw(tab, at: target)
        if select { self.select(tab.id) } else if activeTabID == nil { activeTabID = tab.id }
        normalize()
    }

    /// Inserts without normalizing; resolves the target against the current list.
    private mutating func insertRaw(_ tab: TerminalTab, at target: DropTarget) {
        var tab = tab
        switch target {
        case .beforeTab(let ref):
            guard let j = index(of: ref) else { return insertRaw(tab, at: .end) }
            tab.groupID = tabs[j].groupID
            tabs.insert(tab, at: j)
        case .afterTab(let ref):
            guard let j = index(of: ref) else { return insertRaw(tab, at: .end) }
            tab.groupID = tabs[j].groupID
            tabs.insert(tab, at: j + 1)
        case .intoGroup(let g):
            guard groups[g] != nil else { return insertRaw(tab, at: .end) }
            tab.groupID = g
            if let last = tabs.lastIndex(where: { $0.groupID == g }) {
                tabs.insert(tab, at: last + 1)
            } else {
                tabs.append(tab) // group emptied by the remove half of a move
            }
        case .beforeGroup(let g):
            tab.groupID = nil
            tabs.insert(tab, at: tabs.firstIndex { $0.groupID == g } ?? tabs.endIndex)
        case .afterGroup(let g):
            tab.groupID = nil
            let last = tabs.lastIndex { $0.groupID == g }
            tabs.insert(tab, at: last.map { $0 + 1 } ?? tabs.endIndex)
        case .end:
            tab.groupID = nil
            tabs.append(tab)
        }
    }

    /// Swaps a tab with its left (-1) or right (+1) neighbour, but only if that
    /// neighbour is in the same group (or both are ungrouped). Never changes
    /// membership. Returns whether it moved.
    @discardableResult
    public mutating func shift(tab id: UUID, by direction: Int) -> Bool {
        guard direction == 1 || direction == -1, let i = index(of: id) else { return false }
        let j = i + direction
        guard tabs.indices.contains(j), tabs[j].groupID == tabs[i].groupID else { return false }
        tabs.swapAt(i, j)
        return true
    }

    // MARK: - Groups

    /// Puts a tab into a brand-new group. A tab leaving another group is first
    /// moved to just after that group so groups stay contiguous.
    @discardableResult
    public mutating func createGroup(with tabID: UUID, name: String = "", color: GroupColor? = nil) -> TabGroup? {
        guard let t = tab(tabID) else { return nil }
        if let old = t.groupID {
            move(tab: tabID, to: .afterGroup(old))
        }
        // Registered only after the move: normalize() would drop it while still empty.
        let group = TabGroup(name: name, color: color ?? nextColor())
        groups[group.id] = group
        if let i = index(of: tabID) { tabs[i].groupID = group.id }
        normalize()
        return group
    }

    public mutating func updateGroup(_ id: UUID, _ change: (inout TabGroup) -> Void) {
        guard var g = groups[id] else { return }
        change(&g)
        groups[id] = g
        if g.isCollapsed { moveSelectionOutOfCollapsed() }
    }

    public mutating func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        updateGroup(id) { $0.isCollapsed = collapsed }
    }

    public mutating func toggleCollapsed(_ id: UUID) {
        guard let g = groups[id] else { return }
        setCollapsed(id, !g.isCollapsed)
    }

    /// Dissolves a group; its tabs stay where they are, ungrouped.
    public mutating func ungroup(_ id: UUID) {
        for i in tabs.indices where tabs[i].groupID == id { tabs[i].groupID = nil }
        groups[id] = nil
    }

    /// Moves a tab out of its group to just after the group.
    public mutating func removeFromGroup(tab id: UUID) {
        guard let g = tab(id)?.groupID else { return }
        move(tab: id, to: .afterGroup(g))
    }

    /// Closes every tab in the group; returns the closed tabs.
    public mutating func closeGroup(_ id: UUID) -> [TerminalTab] {
        let members = tabs(in: id)
        members.forEach { removeTab($0.id) }
        groups[id] = nil
        return members
    }

    /// Removes a whole group (for moving it to another window).
    public mutating func extractGroup(_ id: UUID) -> (TabGroup, [TerminalTab])? {
        guard let g = groups[id] else { return nil }
        let members = tabs(in: id)
        let wasActive = members.contains { $0.id == activeTabID }
        tabs.removeAll { $0.groupID == id }
        groups[id] = nil
        if wasActive { activeTabID = visibleTabs.first?.id ?? tabs.first?.id }
        normalize()
        return (g, members)
    }

    /// Inserts a whole group. A target inside another group snaps to that group's start.
    public mutating func insertGroup(_ group: TabGroup, tabs members: [TerminalTab], at target: DropTarget, select: Bool = false) {
        guard !members.isEmpty else { return }
        groups[group.id] = group
        let index = groupInsertionIndex(for: target)
        let placed = members.map { var t = $0; t.groupID = group.id; return t }
        tabs.insert(contentsOf: placed, at: index)
        if select || activeTabID == nil { self.select(placed[0].id) }
        normalize()
    }

    /// Moves a whole group within this window.
    public mutating func moveGroup(_ id: UUID, to target: DropTarget) {
        switch target {
        case .intoGroup(id), .beforeGroup(id), .afterGroup(id): return
        case .beforeTab(let t), .afterTab(let t):
            if tab(t)?.groupID == id { return }
        default: break
        }
        let active = activeTabID
        guard let (g, members) = extractGroup(id) else { return }
        insertGroup(g, tabs: members, at: target)
        if let active, tab(active) != nil { activeTabID = active }
        normalize()
    }

    private func groupInsertionIndex(for target: DropTarget) -> Int {
        var raw: Int
        switch target {
        case .beforeTab(let t): raw = index(of: t) ?? tabs.endIndex
        case .afterTab(let t): raw = index(of: t).map { $0 + 1 } ?? tabs.endIndex
        case .beforeGroup(let g), .intoGroup(let g):
            raw = tabs.firstIndex { $0.groupID == g } ?? tabs.endIndex
        case .afterGroup(let g):
            raw = tabs.lastIndex { $0.groupID == g }.map { $0 + 1 } ?? tabs.endIndex
        case .end: raw = tabs.endIndex
        }
        // Never split another group: snap back to its first tab.
        if raw > 0, raw < tabs.endIndex, let g = tabs[raw].groupID, tabs[raw - 1].groupID == g {
            raw = tabs.firstIndex { $0.groupID == g }!
        }
        return raw
    }

    /// First unused color in this window, else cycles.
    public func nextColor() -> GroupColor {
        let used = Set(groups.values.map(\.color))
        let palette: [GroupColor] = [.blue, .red, .yellow, .green, .pink, .purple, .cyan, .orange, .grey]
        return palette.first { !used.contains($0) } ?? palette[groups.count % palette.count]
    }

    // MARK: - Invariants

    private func isHidden(_ t: TerminalTab) -> Bool {
        t.groupID.flatMap { groups[$0]?.isCollapsed } == true
    }

    private mutating func moveSelectionOutOfCollapsed() {
        guard let active = activeTab, isHidden(active), let i = index(of: active.id) else { return }
        let visible = tabs.indices.filter { !isHidden(tabs[$0]) }
        if let right = visible.first(where: { $0 > i }) { activeTabID = tabs[right].id }
        else if let left = visible.last { activeTabID = tabs[left].id }
        // No visible tab at all: keep the hidden one active so content stays on screen.
    }

    /// Repairs anything a raw edit may have broken. Cheap; called after every mutation.
    private mutating func normalize() {
        // Drop references to missing groups.
        for i in tabs.indices where tabs[i].groupID.map({ groups[$0] == nil }) == true {
            tabs[i].groupID = nil
        }
        // Enforce contiguity by pulling stragglers up to their group's first run.
        var result: [TerminalTab] = []
        var placed = Set<UUID>()
        for t in tabs where !placed.contains(t.id) {
            if let g = t.groupID {
                if result.contains(where: { $0.groupID == g }) { continue } // handled with first run
                for m in tabs where m.groupID == g { result.append(m); placed.insert(m.id) }
            } else {
                result.append(t); placed.insert(t.id)
            }
        }
        tabs = result
        // Drop empty groups.
        let used = Set(tabs.compactMap(\.groupID))
        groups = groups.filter { used.contains($0.key) }
        // Active tab must exist.
        if activeTabID.map({ tab($0) == nil }) ?? true { activeTabID = visibleTabs.first?.id ?? tabs.first?.id }
    }

    /// Human-readable invariant violations; empty when healthy. Used by tests.
    public func violations() -> [String] {
        var out: [String] = []
        var closed = Set<UUID>()
        var current: UUID?
        for t in tabs {
            if t.groupID != current {
                if let c = current { closed.insert(c) }
                if let g = t.groupID, closed.contains(g) { out.append("group \(g) not contiguous") }
                current = t.groupID
            }
            if let g = t.groupID, groups[g] == nil { out.append("tab \(t.id) references missing group") }
        }
        for g in groups.keys where !tabs.contains(where: { $0.groupID == g }) {
            out.append("group \(g) is empty")
        }
        if tabs.isEmpty != (activeTabID == nil) { out.append("activeTabID inconsistent with emptiness") }
        if let a = activeTabID, tab(a) == nil { out.append("activeTabID points at missing tab") }
        if Set(tabs.map(\.id)).count != tabs.count { out.append("duplicate tab ids") }
        return out
    }
}
