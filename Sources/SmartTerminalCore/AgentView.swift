import Foundation

/// Claude Code's agent view: `claude agents` (plain `claude` too, where that opens it)
/// lists the background sessions the Claude Code daemon runs (`claude --bg`), and
/// `claude attach <id>` opens one of them in the terminal; ← goes back to the list.
/// Those sessions live in the daemon, not in the tab, so quitting the app doesn't stop
/// them, and after a restart the tab only has to attach again. `claude --resume` would
/// be wrong here: for a session that is still running it starts a second copy.
///
/// Sources (verified against Claude Code 2.1.325):
/// - the client has no `~/.claude/sessions/<pid>.json` of its own; each background
///   session has one, with `kind: "bg"`, its short `jobId` and its `name`
/// - the list sets the terminal title to "claude agents" ("3 awaiting input · claude agents"),
///   and sets it again when ← brings it back
/// - an attached session's own title comes through ("✳ <name>", a spinner while busy).
///   Attaching to an idle one sets none, so the list's title stays up; and a session
///   whose title isn't its name ("✳ claude") can't be told apart.
public enum AgentViewTitle {
    public static func isList(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespaces).hasSuffix("claude agents")
    }
}

/// `~/.claude/sessions/<pid>.json`, the fields that identify a background session.
public struct BackgroundSessionRecord: Decodable, Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String?
    public let name: String?
    public let kind: String?
    public let jobId: String?

    public init(pid: Int32, sessionId: String, cwd: String? = nil, name: String? = nil,
                kind: String? = "bg", jobId: String? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd
        self.name = name; self.kind = kind; self.jobId = jobId
    }

    public var isBackground: Bool { kind == "bg" && jobId?.isEmpty == false }
}

/// An agent view a tab was running, persisted with the layout so the tab can open it
/// again after the app restarts: the background session it had open, when the
/// terminal title said which, or else the list.
public struct AgentViewRef: Codable, Hashable, Sendable {
    /// The short id `claude attach` takes; nil for the list.
    public var jobID: String?
    public var sessionID: String?
    /// The session's name when it was seen, for the Resume bar. Never typed: `attach`
    /// also takes part of a name, and two sessions can have names alike.
    public var name: String?
    public var cwd: String?

    public init(jobID: String? = nil, sessionID: String? = nil, name: String? = nil, cwd: String? = nil) {
        self.jobID = jobID; self.sessionID = sessionID; self.name = name; self.cwd = cwd
    }

    init(_ r: BackgroundSessionRecord) {
        self.init(jobID: r.jobId, sessionID: r.sessionId, name: r.name, cwd: r.cwd)
    }

    /// The line typed into the tab's shell. Attaching opens what is already running
    /// (or a stopped session again) and never starts a copy.
    public var command: String {
        guard let jobID else { return "claude agents" }
        return "claude attach \(AgentSessionRef.shellQuote(jobID))"
    }
}

/// Follows which background session an agent-view client shows, from its argv and the
/// titles it sets. Only a title set while this client runs counts: the terminal keeps
/// the last title, which may be an earlier program's.
public struct AgentViewTracker: Sendable {
    public private(set) var pid: Int32 = 0
    private var ref = AgentViewRef()
    /// `claude agents` / `claude attach`, or the list's title seen: this client is the
    /// agent view. Until then a `claude` without a session file may be something else
    /// (`claude -p`, an interactive session that hasn't written its file yet).
    private var confirmed = false
    /// The title already up when this client appeared, ignored until it changes.
    private var inheritedTitle: String?
    private var titleIsInherited = false
    /// The session name last looked up, so spinner frames don't re-read the files.
    private var lastName: String?

    public init() {}

    /// What to persist for the client `pid`, or nil while it isn't known to be the
    /// agent view. `sessions` (the live background sessions) is read only when the
    /// title names a session not looked up yet.
    public mutating func update(pid: Int32, arguments: [String], title: String?,
                                sessions: () -> [BackgroundSessionRecord]) -> AgentViewRef? {
        if pid != self.pid {
            self = AgentViewTracker()
            self.pid = pid
            inheritedTitle = title
            titleIsInherited = true
            let sub = Self.subcommand(arguments)
            if sub == "agents" { confirmed = true }
            if sub == "attach" {
                confirmed = true
                if let target = Self.attachTarget(arguments) { ref = Self.resolve(target, in: sessions()) }
            }
        }
        if titleIsInherited, title == inheritedTitle { return confirmed ? ref : nil }
        titleIsInherited = false
        guard let title else { return confirmed ? ref : nil }
        if AgentViewTitle.isList(title) {
            confirmed = true
            ref = AgentViewRef()
            lastName = nil
            return ref
        }
        guard confirmed else { return nil }
        let name = ClaudeTitle.parse(title)?.title ?? title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != lastName else { return ref }
        lastName = name
        let hits = sessions().filter { $0.isBackground && $0.name == name }
        // No match, or several: some session is open, but not one we can name. The list
        // is the safe thing to come back to.
        ref = hits.count == 1 ? AgentViewRef(hits[0]) : AgentViewRef()
        return ref
    }

    /// The first argument that isn't an option: `agents`, `attach`, or a prompt.
    static func subcommand(_ args: [String]) -> String? {
        args.dropFirst().first { !$0.hasPrefix("-") }
    }

    /// `claude attach <id|name>`'s target.
    static func attachTarget(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "attach"), i + 1 < args.count else { return nil }
        let t = args[i + 1]
        return t.hasPrefix("-") ? nil : t
    }

    /// The session `claude attach <target>` opened: by its id, or by a name only one
    /// session has. A bare id is kept even if its session isn't running yet (attach
    /// starts a stopped one again).
    static func resolve(_ target: String, in sessions: [BackgroundSessionRecord]) -> AgentViewRef {
        let bg = sessions.filter(\.isBackground)
        if let r = bg.first(where: { $0.jobId == target }) { return AgentViewRef(r) }
        let named = bg.filter { $0.name == target }
        if named.count == 1 { return AgentViewRef(named[0]) }
        let isID = target.count == 8 && target.allSatisfy(\.isHexDigit)
        return isID ? AgentViewRef(jobID: target) : AgentViewRef()
    }
}
