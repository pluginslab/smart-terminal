import Foundation

/// The nine Chrome tab-group colors.
public enum GroupColor: String, Codable, CaseIterable, Sendable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    public var displayName: String { rawValue.capitalized }
}

public struct TabGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: GroupColor
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String = "", color: GroupColor, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }
}

public struct TerminalTab: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// Set by the user; wins over `autoTitle` when non-empty.
    public var customTitle: String?
    /// Fed by the shell (OSC title) or derived from cwd.
    public var autoTitle: String
    /// Last known working directory; used to respawn the shell on restore.
    public var cwd: String?
    public var groupID: UUID?
    /// Claude Code session running here when last seen; survives quit/crash so it can be resumed.
    public var agentSession: AgentSessionRef?

    public init(id: UUID = UUID(), customTitle: String? = nil, autoTitle: String = "Terminal",
                cwd: String? = nil, groupID: UUID? = nil, agentSession: AgentSessionRef? = nil) {
        self.id = id
        self.customTitle = customTitle
        self.autoTitle = autoTitle
        self.cwd = cwd
        self.groupID = groupID
        self.agentSession = agentSession
    }

    public var displayTitle: String {
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            return customTitle
        }
        return autoTitle
    }
}

/// A plain rect so Core stays free of AppKit/CoreGraphics.
public struct WindowFrame: Codable, Hashable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Where a dragged tab or group should land in a window's strip.
public enum DropTarget: Hashable, Sendable {
    /// Immediately before this tab; joins that tab's group (or none).
    case beforeTab(UUID)
    /// Immediately after this tab; joins that tab's group (or none).
    case afterTab(UUID)
    /// Appended to the end of this group.
    case intoGroup(UUID)
    /// Ungrouped, right before this group's first tab.
    case beforeGroup(UUID)
    /// Ungrouped, right after this group's last tab.
    case afterGroup(UUID)
    /// Ungrouped, at the end of the strip.
    case end
}

/// One renderable element of the tab strip, in order.
public enum StripItem: Identifiable, Hashable, Sendable {
    case chip(TabGroup, tabCount: Int)
    case tab(TerminalTab)

    public var id: UUID {
        switch self {
        case .chip(let g, _): g.id
        case .tab(let t): t.id
        }
    }
}
