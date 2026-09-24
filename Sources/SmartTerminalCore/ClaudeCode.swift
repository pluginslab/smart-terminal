import Foundation

/// What we can learn about a Claude Code session running in a tab.
///
/// Sources (verified against Claude Code 2.1.x):
/// - terminal title (OSC 0/2): "◐ <title>" while busy (◐◓◑◒ spinner), "✳ <title>" when idle
/// - `~/.claude/sessions/<pid>.json`: status busy/idle/shell, sessionId, name, nameSource
/// - `~/.claude/projects/<dir>/<sessionId>.jsonl`: appended `custom-title` (/rename),
///   `ai-title`, `agent-name`, `last-prompt`, `pr-link` entries
public enum AgentStatus: String, Codable, Sendable {
    case busy, idle
    /// A dialog blocks Claude: a permission prompt, a question, an elicitation.
    /// Only the session file knows this; the title just shows ✳.
    case waiting
}

public enum ClaudeTitle {
    static let busyGlyphs: Set<Character> = ["◐", "◓", "◑", "◒",
                                             "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
                                             "·", "✢", "✶", "✻", "✽"]
    static let idleGlyphs: Set<Character> = ["✳"]

    /// Parses Claude Code's terminal title. Returns nil when the title does not
    /// carry Claude's status glyph (so it is some other program's title).
    public static func parse(_ raw: String) -> (status: AgentStatus, title: String)? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return nil }
        let status: AgentStatus
        if idleGlyphs.contains(first) { status = .idle }
        else if busyGlyphs.contains(first) { status = .busy }
        else { return nil }
        let rest = t.dropFirst().trimmingCharacters(in: .whitespaces)
        return (status, rest)
    }
}

/// `~/.claude/sessions/<pid>.json`
public struct ClaudeSessionRecord: Decodable, Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String?
    public let status: String?
    public let name: String?
    public let nameSource: String?
    /// Why it is waiting when status == "waiting", e.g. "input needed", "dialog open".
    public let waitingFor: String?

    public init(pid: Int32, sessionId: String, cwd: String?, status: String?, name: String?,
                nameSource: String?, waitingFor: String? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd
        self.status = status; self.name = name; self.nameSource = nameSource; self.waitingFor = waitingFor
    }

    /// "shell" means Claude is running a `!` command: still working.
    public var agentStatus: AgentStatus? {
        switch status {
        case "busy", "shell": .busy
        case "idle": .idle
        case "waiting": .waiting
        default: nil
        }
    }

    /// Names Claude derives itself ("smart-terminal-92") are folder + noise.
    public var meaningfulName: String? {
        guard let name, !name.isEmpty, nameSource != "derived" else { return nil }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespaces))
    }
}

/// Accumulates the naming-relevant entries of a transcript. Later entries win.
public struct ClaudeTranscriptState: Equatable, Sendable {
    public var customTitle: String?
    public var aiTitle: String?
    public var agentName: String?
    public var lastPrompt: String?
    public var prURL: String?
    public var prNumber: String?

    public init() {}

    /// Cheap prefilter: only lines of these types are decoded.
    static let markers = ["\"custom-title\"", "\"ai-title\"", "\"agent-name\"", "\"last-prompt\"", "\"pr-link\""]

    public var hasTitle: Bool { customTitle != nil || aiTitle != nil || agentName != nil }

    /// Feeds one JSONL line. Unrelated or malformed lines are ignored.
    public mutating func ingest(line: some StringProtocol) {
        guard Self.markers.contains(where: { line.contains($0) }),
              let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        func str(_ k: String) -> String? {
            let v: String? = (obj[k] as? String) ?? (obj[k] as? Int).map(String.init)
            guard let v else { return nil }
            let t = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
            return t.isEmpty ? nil : t
        }
        switch type {
        case "custom-title": customTitle = str("customTitle")
        case "ai-title": aiTitle = str("aiTitle") ?? aiTitle
        case "agent-name": agentName = str("agentName") ?? agentName
        case "last-prompt": lastPrompt = str("lastPrompt") ?? lastPrompt
        case "pr-link": prURL = str("prUrl") ?? prURL; prNumber = str("prNumber") ?? prNumber
        default: break
        }
    }
}

/// Everything the UI needs about the Claude session in a tab.
public struct AgentSnapshot: Equatable, Sendable {
    public var status: AgentStatus
    public var waitingFor: String?
    public var title: String?
    public var lastPrompt: String?
    public var prNumber: String?
    public var prURL: String?
    public var sessionID: String?

    public init(status: AgentStatus, title: String? = nil, lastPrompt: String? = nil,
                prNumber: String? = nil, prURL: String? = nil, sessionID: String? = nil) {
        self.status = status; self.title = title; self.lastPrompt = lastPrompt
        self.prNumber = prNumber; self.prURL = prURL; self.sessionID = sessionID
    }

    /// Priority: /rename > AI title > agent name > non-derived session name > terminal title.
    public static func make(record: ClaudeSessionRecord?, transcript: ClaudeTranscriptState?,
                            terminalTitle: (status: AgentStatus, title: String)?) -> AgentSnapshot? {
        guard let status = record?.agentStatus ?? terminalTitle?.status else { return nil }
        let candidates: [String?] = [transcript?.customTitle, transcript?.aiTitle, transcript?.agentName,
                                     record?.meaningfulName, terminalTitle?.title]
        let title = candidates.lazy.compactMap { $0 }.first { !$0.isEmpty && $0 != "Claude Code" }
        var snap = AgentSnapshot(status: status, title: title, lastPrompt: transcript?.lastPrompt,
                             prNumber: transcript?.prNumber, prURL: transcript?.prURL,
                             sessionID: record?.sessionId)
        if status == .waiting { snap.waitingFor = record?.waitingFor }
        return snap
    }
}

/// A Claude Code session that was running in a tab, persisted with the layout so
/// it can be resumed after the app restarts.
public struct AgentSessionRef: Codable, Hashable, Sendable {
    public var sessionID: String
    public var title: String?
    /// argv of the original `claude` invocation, e.g. ["claude", "--dangerously-skip-permissions"].
    public var arguments: [String]

    public init(sessionID: String, title: String?, arguments: [String]) {
        self.sessionID = sessionID; self.title = title; self.arguments = arguments
    }

    /// Flags that pick a session or make the run non-interactive; dropped before
    /// adding `--resume <id>`. Value-taking ones also drop their value.
    static let dropWithValue: Set<String> = ["--resume", "-r", "--session-id", "--from-pr"]
    static let dropAlone: Set<String> = ["--continue", "-c", "--fork-session"]

    /// Shell command line that resumes this session with the original flags,
    /// e.g. `claude --dangerously-skip-permissions --resume 9b4e…`.
    public var resumeCommand: String {
        var args = arguments.isEmpty ? ["claude"] : arguments
        let program = args.removeFirst()
        var kept: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
            if Self.dropWithValue.contains(name) {
                // `--resume id` consumes the next arg unless it is `--resume=id` or the value is absent.
                if !a.contains("="), i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
            } else if !Self.dropAlone.contains(a) {
                kept.append(a)
            }
            i += 1
        }
        // A `claude "some prompt"` positional would start a new turn; drop plain positionals.
        kept = kept.enumerated().filter { idx, a in
            a.hasPrefix("-") || (idx > 0 && kept[idx - 1].hasPrefix("--") && !kept[idx - 1].contains("="))
        }.map(\.element)
        let base = program == "claude" || program.hasSuffix("/claude") || program.first?.isNumber == true ? "claude" : program
        return ([base] + kept + ["--resume", sessionID]).map(Self.shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,+%"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
