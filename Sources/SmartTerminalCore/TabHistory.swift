import Foundation

/// The tabs a window showed, in order, for Back and Forward (as in Slack or a browser).
///
/// Every tab shown is a visit, however it was chosen. Going back or forward moves
/// through the list without adding to it; showing a tab from anywhere else drops what
/// was ahead. Tabs closed or moved away since are skipped, not removed: `exists` says
/// which still count.
public struct TabHistory: Equatable, Sendable {
    public static let limit = 100

    public private(set) var entries: [UUID] = []
    public private(set) var index = -1

    public init() {}

    public var current: UUID? { entries.indices.contains(index) ? entries[index] : nil }

    /// `id` is now shown.
    public mutating func visit(_ id: UUID) {
        guard current != id else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(id)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    /// The position Back (-1) or Forward (+1) leads to: the nearest entry that still
    /// exists and isn't the tab shown now.
    private func step(_ direction: Int, exists: (UUID) -> Bool) -> Int? {
        var i = index + direction
        while entries.indices.contains(i) {
            if entries[i] != current, exists(entries[i]) { return i }
            i += direction
        }
        return nil
    }

    public func canMove(_ direction: Int, exists: (UUID) -> Bool) -> Bool {
        step(direction, exists: exists) != nil
    }

    /// Goes back (-1) or forward (+1); returns the tab to show.
    public mutating func move(_ direction: Int, exists: (UUID) -> Bool) -> UUID? {
        guard let i = step(direction, exists: exists) else { return nil }
        index = i
        return entries[i]
    }
}
