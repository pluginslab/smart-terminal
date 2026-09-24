import Foundation

/// Every window in the app. Owns cross-window moves.
public struct AppLayout: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var windows: [WindowLayout]

    public init(windows: [WindowLayout] = []) {
        self.version = Self.currentVersion
        self.windows = windows
    }

    public func windowIndex(_ id: UUID) -> Int? { windows.firstIndex { $0.id == id } }
    public func window(_ id: UUID) -> WindowLayout? { windows.first { $0.id == id } }

    public func windowID(containingTab tabID: UUID) -> UUID? {
        windows.first { $0.tab(tabID) != nil }?.id
    }

    public func windowID(containingGroup groupID: UUID) -> UUID? {
        windows.first { $0.group(groupID) != nil }?.id
    }

    public mutating func update(_ windowID: UUID, _ change: (inout WindowLayout) -> Void) {
        guard let i = windowIndex(windowID) else { return }
        change(&windows[i])
    }

    /// Moves a tab anywhere: same window or another. Returns the source window id
    /// when that window became empty (the caller should close it).
    @discardableResult
    public mutating func moveTab(_ tabID: UUID, toWindow dest: UUID, at target: DropTarget) -> UUID? {
        guard let src = windowID(containingTab: tabID), let di = windowIndex(dest) else { return nil }
        if src == dest {
            windows[di].move(tab: tabID, to: target)
            windows[di].select(tabID)
            return nil
        }
        guard let si = windowIndex(src), let tab = windows[si].removeTab(tabID) else { return nil }
        windows[di].insert(tab, at: target, select: true)
        return windows[si].isEmpty ? src : nil
    }

    /// Moves a whole group anywhere. Returns the emptied source window id, if any.
    @discardableResult
    public mutating func moveGroup(_ groupID: UUID, toWindow dest: UUID, at target: DropTarget) -> UUID? {
        guard let src = windowID(containingGroup: groupID), let di = windowIndex(dest) else { return nil }
        if src == dest {
            windows[di].moveGroup(groupID, to: target)
            return nil
        }
        guard let si = windowIndex(src), let (g, members) = windows[si].extractGroup(groupID) else { return nil }
        windows[di].insertGroup(g, tabs: members, at: target, select: true)
        return windows[si].isEmpty ? src : nil
    }

    /// Detaches a tab into a new window (appended to `windows`). Returns the new
    /// window id and, if the source became empty, its id.
    public mutating func detachTab(_ tabID: UUID, frame: WindowFrame? = nil) -> (newWindow: UUID, emptied: UUID?)? {
        guard let src = windowID(containingTab: tabID), let si = windowIndex(src),
              windows[si].tabs.count > 1,
              let tab = windows[si].removeTab(tabID) else { return nil }
        var w = WindowLayout(frame: frame)
        w.insert(tab, at: .end)
        windows.append(w)
        return (w.id, windows[si].isEmpty ? src : nil)
    }

    /// Detaches a whole group into a new window.
    public mutating func detachGroup(_ groupID: UUID, frame: WindowFrame? = nil) -> (newWindow: UUID, emptied: UUID?)? {
        guard let src = windowID(containingGroup: groupID), let si = windowIndex(src),
              let (g, members) = windows[si].extractGroup(groupID) else { return nil }
        var w = WindowLayout(frame: frame)
        w.insertGroup(g, tabs: members, at: .end, select: true)
        windows.append(w)
        return (w.id, windows[si].isEmpty ? src : nil)
    }

    public mutating func removeWindow(_ id: UUID) {
        windows.removeAll { $0.id == id }
    }
}
