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
    /// Epoch milliseconds.
    public let startedAt: Double?

    public init(pid: Int32, sessionId: String, cwd: String?, status: String?, name: String?,
                nameSource: String?, waitingFor: String? = nil, startedAt: Double? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd
        self.status = status; self.name = name; self.nameSource = nameSource; self.waitingFor = waitingFor
        self.startedAt = startedAt
    }

    public var startDate: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

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

/// A subagent Claude started with its Agent tool.
public struct ClaudeSubagent: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case running, completed, failed }

    /// The Agent tool call's id; results and notifications refer back to it.
    public let id: String
    public var description: String
    public var type: String?
    public var background: Bool
    public var status: Status = .running
    public var startedAt: Date?
    public var finishedAt: Date?
    public var duration: TimeInterval?
    public var totalTokens: Int?
    public var toolUses: Int?

    public init(id: String, description: String, type: String? = nil, background: Bool = false,
                status: Status = .running, startedAt: Date? = nil) {
        self.id = id; self.description = description; self.type = type
        self.background = background; self.status = status; self.startedAt = startedAt
    }
}

/// Token use and turn timing, accumulated from a session transcript.
///
/// One API response is logged as several lines (one per content block), each
/// repeating the same usage, so totals count each message id once.
public struct ClaudeUsage: Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheCreationTokens = 0
    /// Size of the context at the latest reply: its input plus cache tokens.
    public var contextTokens = 0
    public var peakContextTokens = 0
    public var model: String?
    /// Prompts you typed (not tool results, slash-command output or subagent turns).
    public var prompts = 0
    public var lastPromptAt: Date?
    public var lastReplyAt: Date?
    public var lastTurnDuration: TimeInterval?
    /// Window stated by `/context` or `/model` output in the transcript (latest wins).
    public var declaredWindow: Int?
    /// From outside the transcript: `~/.claude.json` shows this folder last used the 1M model.
    public var lastUsedWindow: Int?
    /// In launch order. Only the main conversation's; nested ones live in subagent transcripts.
    public var subagents: [ClaudeSubagent] = []
    /// `prompts` when the last subagent was launched: a higher count means a new prompt.
    private var promptsAtLastLaunch = 0
    /// When this Claude process started. A subagent launched before it (the session
    /// was resumed) that never finished won't report back, so it counts as done.
    public var processStart: Date?
    private var seen: Set<String> = []

    public init(processStart: Date? = nil) { self.processStart = processStart }

    /// Launched before this process and never finished: it will never report back.
    public func isStale(_ a: ClaudeSubagent) -> Bool {
        guard a.status == .running, let start = a.startedAt, let processStart else { return false }
        return start < processStart
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    public enum WindowSource: Sendable { case declared, observed, lastUsed, assumed }

    /// Replies log the model without its "[1m]" suffix, so the window comes from,
    /// in order: `/context` or `/model` output, a context already past 200k, the
    /// folder's last-used model, else an assumed 200k.
    public var contextWindow: (tokens: Int, source: WindowSource) {
        if let declaredWindow { return (declaredWindow, .declared) }
        if peakContextTokens > 200_000 { return (1_000_000, .observed) }
        if let lastUsedWindow { return (lastUsedWindow, .lastUsed) }
        return (200_000, .assumed)
    }

    /// Cheap prefilter; only these lines are decoded.
    static let markers = ["\"assistant\"", "\"user\"", "\"turn_duration\"", "\"local_command\"",
                          "\"queue-operation\"", "\"queued_command\""]

    public mutating func ingest(line: some StringProtocol) {
        guard Self.markers.contains(where: { line.contains($0) }),
              let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let sidechain = obj["isSidechain"] as? Bool == true
        let time = (obj["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
        switch type {
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            func n(_ k: String) -> Int { usage[k] as? Int ?? 0 }
            let id = message["id"] as? String ?? UUID().uuidString
            if seen.insert(id).inserted {
                inputTokens += n("input_tokens")
                outputTokens += n("output_tokens")
                cacheReadTokens += n("cache_read_input_tokens")
                cacheCreationTokens += n("cache_creation_input_tokens")
            }
            guard !sidechain else { return }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use"
                && ["Agent", "Task"].contains(block["name"] as? String ?? "") {
                guard let id = block["id"] as? String, !subagents.contains(where: { $0.id == id }) else { continue }
                // A new prompt's first subagent starts a fresh list, if the previous
                // ones all completed. Running or failed ones keep it, so they aren't missed.
                if prompts > promptsAtLastLaunch, subagents.allSatisfy({ $0.status == .completed || isStale($0) }) {
                    subagents.removeAll()
                }
                promptsAtLastLaunch = prompts
                let input = block["input"] as? [String: Any] ?? [:]
                subagents.append(ClaudeSubagent(
                    id: id, description: input["description"] as? String ?? "Subagent",
                    type: input["subagent_type"] as? String,
                    background: input["run_in_background"] as? Bool == true, startedAt: time))
            }
            if let m = message["model"] as? String, m != "<synthetic>" { model = m }
            let context = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
            if context > 0 { contextTokens = context; peakContextTokens = max(peakContextTokens, context) }
            if let time { lastReplyAt = time }
        case "user":
            guard !sidechain else { return }
            if let message = obj["message"] as? [String: Any] { trackSubagents(message["content"], result: obj["toolUseResult"], time: time) }
            guard obj["toolUseResult"] == nil, obj["isMeta"] as? Bool != true,
                  let message = obj["message"] as? [String: Any], Self.isTypedPrompt(message["content"]) else { return }
            prompts += 1
            if let time { lastPromptAt = time }
        case "queue-operation":
            // A background subagent that finishes while Claude is mid-turn has its
            // notification queued; the enqueue is the moment it finished.
            if obj["operation"] as? String == "enqueue", let text = obj["content"] as? String {
                finishSubagents(notifications: text, time: time)
            }
        case "attachment":
            // ...and the queued notification is later delivered as an attachment.
            if let a = obj["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
               a["commandMode"] as? String == "task-notification", let text = a["prompt"] as? String {
                finishSubagents(notifications: text, time: time)
            }
        case "system":
            guard !sidechain else { return }
            switch obj["subtype"] as? String {
            case "turn_duration":
                if let ms = obj["durationMs"] as? Double { lastTurnDuration = ms / 1000 }
            case "local_command":
                if let text = obj["content"] as? String, let w = Self.window(inCommandOutput: text) { declaredWindow = w }
            default:
                break
            }
        default:
            break
        }
    }

    /// Finishes subagents: a regular one by its tool result (status and stats in
    /// `toolUseResult`), a background one by a `<task-notification>` naming its tool call.
    private mutating func trackSubagents(_ content: Any?, result: Any?, time: Date?) {
        let text = (content as? String)
            ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if let text, text.contains("<task-notification>") {
            finishSubagents(notifications: text, time: time)
            return
        }
        for block in content as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
            guard let toolID = block["tool_use_id"] as? String,
                  let i = subagents.firstIndex(where: { $0.id == toolID }) else { continue }
            let r = result as? [String: Any] ?? [:]
            if r["status"] as? String == "async_launched" { subagents[i].background = true; continue }
            subagents[i].status = block["is_error"] as? Bool == true || (r["status"] as? String).map({ $0 != "completed" }) == true
                ? .failed : .completed
            subagents[i].finishedAt = time
            if let ms = r["totalDurationMs"] as? Double { subagents[i].duration = ms / 1000 }
            else if let start = subagents[i].startedAt, let time { subagents[i].duration = time.timeIntervalSince(start) }
            subagents[i].totalTokens = r["totalTokens"] as? Int
            subagents[i].toolUses = r["totalToolUseCount"] as? Int
        }
    }

    /// Every `<task-notification>` in `text` (several can arrive together). The first
    /// one for a subagent wins, so a queued notification delivered later isn't counted twice.
    private mutating func finishSubagents(notifications text: String, time: Date?) {
        for chunk in text.components(separatedBy: "<task-notification>").dropFirst() {
            guard let toolID = Self.tag("tool-use-id", in: chunk),
                  let i = subagents.firstIndex(where: { $0.id == toolID }),
                  subagents[i].status == .running else { continue }
            subagents[i].status = Self.tag("status", in: chunk) == "completed" ? .completed : .failed
            subagents[i].finishedAt = time
            // The notification's own stats; the timestamps would include the queueing delay.
            if let ms = Self.tag("duration_ms", in: chunk).flatMap(Double.init) { subagents[i].duration = ms / 1000 }
            else if let start = subagents[i].startedAt, let time { subagents[i].duration = time.timeIntervalSince(start) }
            subagents[i].totalTokens = Self.tag("subagent_tokens", in: chunk).flatMap { Int($0) }
            subagents[i].toolUses = Self.tag("tool_uses", in: chunk).flatMap { Int($0) }
        }
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `/context` prints "Opus 5.5 (1M context)" and "claude-opus-5-5[1m]"; `/model`
    /// prints "Set model to …". Nil for output that says nothing about the model.
    static func window(inCommandOutput text: String) -> Int? {
        if text.contains("(1M context)") || text.contains("[1m]") { return 1_000_000 }
        if text.contains("Set model to") || text.contains("Context Usage") { return 200_000 }
        return nil
    }

    /// Whether `~/.claude.json` shows `folder` last used the 1M variant of `model`.
    /// It's written when a session ends, so it describes the folder's previous session.
    public static func lastUsedWindow(claudeJSON: Data, folder: String, model: String) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: claudeJSON) as? [String: Any],
              let projects = root["projects"] as? [String: Any],
              let project = projects[folder] as? [String: Any],
              let usage = project["lastModelUsage"] as? [String: Any] else { return nil }
        if usage["\(model)[1m]"] != nil { return 1_000_000 }
        if usage[model] != nil { return 200_000 }
        return nil
    }

    /// Text you typed: not a tool result, and not the `<command-…>` / `<local-command-…>`
    /// wrappers Claude Code logs for slash commands.
    private static func isTypedPrompt(_ content: Any?) -> Bool {
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && !t.hasPrefix("<")
        }
        guard let blocks = content as? [[String: Any]] else { return false }
        let types = blocks.compactMap { $0["type"] as? String }
        guard !types.contains("tool_result") else { return false }
        return blocks.contains { ($0["type"] as? String) == "text"
            && !(($0["text"] as? String)?.hasPrefix("<") ?? true) }
    }
}

extension ClaudeUsage: Equatable {
    public static func == (a: Self, b: Self) -> Bool {
        a.inputTokens == b.inputTokens && a.outputTokens == b.outputTokens
            && a.cacheReadTokens == b.cacheReadTokens && a.cacheCreationTokens == b.cacheCreationTokens
            && a.contextTokens == b.contextTokens && a.peakContextTokens == b.peakContextTokens
            && a.model == b.model && a.prompts == b.prompts && a.lastPromptAt == b.lastPromptAt
            && a.lastReplyAt == b.lastReplyAt && a.lastTurnDuration == b.lastTurnDuration
            && a.declaredWindow == b.declaredWindow && a.lastUsedWindow == b.lastUsedWindow
            && a.subagents == b.subagents
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
    public var startedAt: Date?
    /// Started with --resume / --continue: the transcript predates this process.
    public var resumed = false
    public var usage: ClaudeUsage?
    /// The session transcript; its subagents' transcripts are in `<name>/subagents/`.
    public var transcriptPath: String?

    public init(status: AgentStatus, title: String? = nil, lastPrompt: String? = nil,
                prNumber: String? = nil, prURL: String? = nil, sessionID: String? = nil) {
        self.status = status; self.title = title; self.lastPrompt = lastPrompt
        self.prNumber = prNumber; self.prURL = prURL; self.sessionID = sessionID
    }

    /// Priority: /rename > AI title > agent name > non-derived session name > terminal title.
    public static func make(record: ClaudeSessionRecord?, transcript: ClaudeTranscriptState?,
                            terminalTitle: (status: AgentStatus, title: String)?,
                            usage: ClaudeUsage? = nil, arguments: [String] = []) -> AgentSnapshot? {
        guard let status = record?.agentStatus ?? terminalTitle?.status else { return nil }
        let candidates: [String?] = [transcript?.customTitle, transcript?.aiTitle, transcript?.agentName,
                                     record?.meaningfulName, terminalTitle?.title]
        let title = candidates.lazy.compactMap { $0 }.first { !$0.isEmpty && $0 != "Claude Code" }
        var snap = AgentSnapshot(status: status, title: title, lastPrompt: transcript?.lastPrompt,
                             prNumber: transcript?.prNumber, prURL: transcript?.prURL,
                             sessionID: record?.sessionId)
        if status == .waiting { snap.waitingFor = record?.waitingFor }
        snap.startedAt = record?.startDate
        snap.usage = usage
        snap.resumed = arguments.contains { ["--resume", "-r", "--continue", "-c"].contains($0) }
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

/// A subagent's transcript as lines for a mini terminal, in Claude Code's own style:
/// its instructions, what it says, and each tool call with the start of its result.
public struct SubagentActivity: Equatable, Sendable {
    public enum Entry: Equatable, Sendable {
        case task(String)
        case text(String)
        case tool(id: String, name: String, summary: String, result: String?, isError: Bool)
    }

    public private(set) var entries: [Entry] = []
    public private(set) var model: String?

    public init() {}

    static let resultLines = 6

    public mutating func ingest(line: some StringProtocol) {
        guard line.contains("\"assistant\"") || line.contains("\"user\""),
              let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let message = obj["message"] as? [String: Any] else { return }
        let content = message["content"]
        switch type {
        case "assistant":
            if let m = message["model"] as? String, m != "<synthetic>" { model = m }
            for block in content as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        entries.append(.text(t))
                    }
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    entries.append(.tool(id: id, name: name, summary: Self.summary(name, block["input"] as? [String: Any] ?? [:]),
                                         result: nil, isError: false))
                default:
                    break
                }
            }
        case "user":
            if let s = content as? String {
                // The first user line is the task Claude gave the subagent.
                if entries.isEmpty { entries.append(.task(s.trimmingCharacters(in: .whitespacesAndNewlines))) }
                return
            }
            for block in content as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String,
                      let i = entries.lastIndex(where: { if case .tool(id, _, _, _, _) = $0 { true } else { false } }),
                      case .tool(_, let name, let summary, _, _) = entries[i] else { continue }
                entries[i] = .tool(id: id, name: name, summary: summary,
                                   result: Self.firstLines(Self.text(of: block["content"])),
                                   isError: block["is_error"] as? Bool == true)
            }
        default:
            break
        }
    }

    /// What goes in the parentheses: `Bash(git status)`, `Read(Sources/App.swift)`.
    static func summary(_ tool: String, _ input: [String: Any]) -> String {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let raw: String? = switch tool {
        case "Bash": s("command")
        case "Read", "Edit", "Write", "NotebookEdit": s("file_path").map { ($0 as NSString).abbreviatingWithTildeInPath }
        case "Grep", "Glob": s("pattern")
        case "WebFetch": s("url")
        case "WebSearch": s("query")
        case "Agent", "Task": s("description")
        default: input.values.lazy.compactMap { $0 as? String }.first
        }
        let one = (raw ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
        return one.count > 160 ? String(one.prefix(160)) + "…" : one
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func firstLines(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no output)" }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(resultLines).map { $0.count > 200 ? $0.prefix(200) + "…" : $0 }.joined(separator: "\n")
        return lines.count > resultLines ? head + "\n… +\(lines.count - resultLines) lines" : head
    }
}
