import Foundation

/// One tab found in Terminal.app, classified by what runs in it.
public struct ImportCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Plain shell (or a command that can't be moved, e.g. ssh or vim, shown for information).
        case shell(runningCommand: String?)
        /// Claude Code: handed over with /exit there, `--resume` here.
        case claude(ref: AgentSessionRef, pid: Int32, busy: Bool)
        /// `tmux attach`: reattached here, Terminal.app's client detached.
        case tmux(session: String)
    }

    public var id: String { tty }
    public let tty: String
    public let terminalWindowID: Int
    public let terminalTabIndex: Int
    public let cwd: String?
    /// Terminal.app's custom title (a user name, or a title a program set).
    public let customTitle: String?
    public let kind: Kind

    public init(tty: String, terminalWindowID: Int, terminalTabIndex: Int, cwd: String?,
                customTitle: String?, kind: Kind) {
        self.tty = tty; self.terminalWindowID = terminalWindowID; self.terminalTabIndex = terminalTabIndex
        self.cwd = cwd; self.customTitle = customTitle; self.kind = kind
    }

    /// Project folder used for grouping ("my-project"); home is "~".
    public var folderName: String {
        guard let cwd, !cwd.isEmpty else { return "Imported" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    /// Name for the new tab. Claude and plain shells name themselves; a tmux
    /// session name is the most useful label for tmux tabs.
    public var tabTitle: String? {
        switch kind {
        case .tmux(let session): return session
        case .claude: return nil
        case .shell:
            // Program-set titles (Claude's ✳/◐ titles, user@host:path) are not user names.
            guard let t = customTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
                  ClaudeTitle.parse(t) == nil, !t.contains("@") else { return nil }
            return t
        }
    }

    /// Checked by default in the import sheet. Busy Claude sessions are not,
    /// because handing over means /exit mid-work.
    public var selectedByDefault: Bool {
        if case .claude(_, _, let busy) = kind { return !busy }
        return true
    }
}

public enum TerminalImportPlan {
    /// Groups candidates by project folder, in first-seen order.
    public static func groups(_ candidates: [ImportCandidate]) -> [(name: String, members: [ImportCandidate])] {
        var order: [String] = []
        var byName: [String: [ImportCandidate]] = [:]
        for c in candidates {
            if byName[c.folderName] == nil { order.append(c.folderName) }
            byName[c.folderName, default: []].append(c)
        }
        return order.map { ($0, byName[$0]!) }
    }
}

extension WindowLayout {
    /// Appends imported tabs as named groups. A group with the same name that
    /// already exists in this window is reused. Returns the created tabs, in order.
    @discardableResult
    public mutating func importGroups(_ groups: [(name: String, tabs: [TerminalTab])]) -> [TerminalTab] {
        var added: [TerminalTab] = []
        for (name, tabs) in groups where !tabs.isEmpty {
            var groupID = orderedGroups.first { $0.name == name }?.id
            for tab in tabs {
                if let g = groupID {
                    insert(tab, at: .intoGroup(g), select: false)
                } else {
                    insert(tab, at: .end, select: false)
                    groupID = createGroup(with: tab.id, name: name)?.id
                }
                added.append(tab)
            }
        }
        return added
    }
}
