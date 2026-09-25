import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct ClaudeCodeTests {
    @Test func parsesTerminalTitles() {
        #expect(ClaudeTitle.parse("✳ Terminal.app replica")! == (.idle, "Terminal.app replica"))
        #expect(ClaudeTitle.parse("◑ Ok")! == (.busy, "Ok"))
        #expect(ClaudeTitle.parse("✳ Claude Code")! == (.idle, "Claude Code"))
        #expect(ClaudeTitle.parse("vim README.md") == nil)
        #expect(ClaudeTitle.parse("") == nil)
    }

    @Test func sessionRecordDecodesRealFile() throws {
        let json = #"{"pid":25965,"sessionId":"9b4e","cwd":"/x","startedAt":1,"kind":"interactive","name":"smart-terminal-92","nameSource":"derived","status":"shell","extra":[1]}"#
        let r = try JSONDecoder().decode(ClaudeSessionRecord.self, from: Data(json.utf8))
        #expect(r.agentStatus == .busy)
        #expect(r.meaningfulName == nil)
        let named = try JSONDecoder().decode(ClaudeSessionRecord.self,
            from: Data(#"{"pid":1,"sessionId":"a","name":"\"Release notes\"","status":"idle"}"#.utf8))
        #expect(named.meaningfulName == "Release notes")
        #expect(named.agentStatus == .idle)
    }

    @Test func transcriptLaterEntriesWin() {
        var s = ClaudeTranscriptState()
        let lines = [
            #"{"type":"user","message":"mentions \"ai-title\" in text but is not one"}"#,
            #"{"type":"ai-title","aiTitle":"First idea","sessionId":"x"}"#,
            #"{"type":"last-prompt","lastPrompt":"fix the drag bug","sessionId":"x"}"#,
            #"{"type":"pr-link","prNumber":28,"prUrl":"https://github.com/o/r/pull/28"}"#,
            #"{"type":"ai-title","aiTitle":"Terminal tab groups","sessionId":"x"}"#,
            "not json at all \"ai-title\"",
        ]
        lines.forEach { s.ingest(line: $0) }
        #expect(s.aiTitle == "Terminal tab groups")
        #expect(s.lastPrompt == "fix the drag bug")
        #expect(s.prNumber == "28")
        #expect(s.customTitle == nil)
        s.ingest(line: #"{"type":"custom-title","customTitle":"\"Release notes\""}"#)
        #expect(s.customTitle == "Release notes")
    }

    @Test func usageCountsEachMessageOnceAndTracksContext() {
        var u = ClaudeUsage()
        // One response logged as two blocks with the same id and usage: counted once.
        let usage = #""usage":{"input_tokens":2,"cache_creation_input_tokens":500,"cache_read_input_tokens":240000,"output_tokens":458}"#
        u.ingest(line: #"{"type":"assistant","timestamp":"2026-09-25T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"thinking"}],"# + usage + "}}")
        u.ingest(line: #"{"type":"assistant","timestamp":"2026-09-25T10:00:01.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text"}],"# + usage + "}}")
        #expect(u.outputTokens == 458)
        #expect(u.cacheReadTokens == 240_000)
        #expect(u.contextTokens == 240_502)
        #expect(u.contextWindow == (1_000_000, .observed)) // past 200k, so it must be the 1M window
        #expect(u.model == "claude-opus-5-5")
        // Subagent replies add to the totals but don't change the main context.
        u.ingest(line: #"{"type":"assistant","isSidechain":true,"message":{"id":"s1","model":"claude-haiku","usage":{"input_tokens":10,"output_tokens":5}}}"#)
        #expect(u.outputTokens == 463)
        #expect(u.contextTokens == 240_502)
        #expect(u.model == "claude-opus-5-5")
    }

    @Test func usageCountsOnlyTypedPrompts() {
        var u = ClaudeUsage()
        let lines = [
            #"{"type":"user","timestamp":"2026-09-25T10:00:00.000Z","message":{"role":"user","content":"fix the bug"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"toolUseResult":{}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat"}}"#,
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent task"}}"#,
            #"{"type":"user","timestamp":"2026-09-25T10:05:00.000Z","message":{"role":"user","content":[{"type":"text","text":"and ship it"},{"type":"image"}]}}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":192000}"#,
        ]
        lines.forEach { u.ingest(line: $0) }
        #expect(u.prompts == 2)
        #expect(u.lastPromptAt == Date(timeIntervalSince1970: 1_790_330_700))
        #expect(u.lastTurnDuration == 192)
        #expect(u.contextWindow == (200_000, .assumed))
        // /context output names the model; it beats every guess.
        u.lastUsedWindow = 200_000
        #expect(u.contextWindow == (200_000, .lastUsed))
        u.ingest(line: #"{"type":"system","subtype":"local_command","content":"<local-command-stdout> \u001b[1mContext Usage\u001b[22m  Opus 5.5 (1M context)\n claude-opus-5-5[1m]"}"#)
        #expect(u.contextWindow == (1_000_000, .declared))
        u.ingest(line: #"{"type":"system","subtype":"local_command","content":"<local-command-stdout>Set model to Sonnet 5</local-command-stdout>"}"#)
        #expect(u.contextWindow == (200_000, .declared))
    }

    @Test func tracksSubagentsFromLaunchToFinish() {
        var u = ClaudeUsage()
        let lines = [
            // Two launches in one reply: a regular one and a background one.
            #"{"type":"assistant","timestamp":"2026-09-25T10:00:00.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Find the drop bug","subagent_type":"Explore"}},{"type":"tool_use","id":"t2","name":"Agent","input":{"description":"Research pricing","subagent_type":"general-purpose","run_in_background":true}},{"type":"tool_use","id":"t3","name":"Bash","input":{}}],"usage":{}}}"#,
            #"{"type":"user","timestamp":"2026-09-25T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"Async agent launched"}]},"toolUseResult":{"status":"async_launched","agentId":"a2"}}"#,
            #"{"type":"user","timestamp":"2026-09-25T10:01:30.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"found it"}]},"toolUseResult":{"status":"completed","totalDurationMs":90000,"totalTokens":41000,"totalToolUseCount":12}}"#,
        ]
        lines.forEach { u.ingest(line: $0) }
        #expect(u.subagents.map(\.description) == ["Find the drop bug", "Research pricing"])
        #expect(u.subagents[0].status == .completed)
        #expect(u.subagents[0].duration == 90)
        #expect(u.subagents[0].totalTokens == 41_000)
        #expect(u.subagents[0].toolUses == 12)
        #expect(u.subagents[1].status == .running)
        #expect(u.subagents[1].background)
        // The background one finishes through a task notification.
        u.ingest(line: #"{"type":"user","timestamp":"2026-09-25T10:05:00.000Z","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>\n<task-id>a2</task-id>\n<tool-use-id>t2</tool-use-id>\n<status>completed</status>\n<summary>Agent finished</summary>"}}"#)
        #expect(u.subagents[1].status == .completed)
        #expect(u.subagents[1].duration == 300)
        #expect(u.prompts == 0) // neither results nor notifications are prompts
    }

    @Test func newPromptClearsFinishedSubagents() {
        func launch(_ id: String, _ t: String) -> String {
            #"{"type":"assistant","timestamp":"2026-09-25T10:0"# + t + #":00.000Z","message":{"id":"m"# + id + #"","content":[{"type":"tool_use","id":""# + id + #"","name":"Agent","input":{"description":""# + id + #""}}],"usage":{}}}"#
        }
        func done(_ id: String, error: Bool = false) -> String {
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":""# + id + #"","is_error":"# + (error ? "true" : "false") + #"}]},"toolUseResult":{"status":""# + (error ? "failed" : "completed") + #""}}"#
        }
        let prompt = #"{"type":"user","message":{"role":"user","content":"next task"}}"#
        var u = ClaudeUsage()
        [prompt, launch("a", "1"), launch("b", "1"), done("a"), done("b")].forEach { u.ingest(line: $0) }
        #expect(u.subagents.map(\.id) == ["a", "b"])
        // All green, new prompt, new subagent: the list starts over.
        [prompt, launch("c", "2")].forEach { u.ingest(line: $0) }
        #expect(u.subagents.map(\.id) == ["c"])
        // A second launch for the same prompt adds to the list.
        u.ingest(line: launch("d", "2"))
        #expect(u.subagents.map(\.id) == ["c", "d"])
        // One failed: the next prompt's subagents are added, not a fresh list.
        [done("c"), done("d", error: true), prompt, launch("e", "3")].forEach { u.ingest(line: $0) }
        #expect(u.subagents.map(\.id) == ["c", "d", "e"])
        // Still running (e): kept too.
        [prompt, launch("f", "4")].forEach { u.ingest(line: $0) }
        #expect(u.subagents.map(\.id) == ["c", "d", "e", "f"])
    }

    @Test func staleSubagentsDontBlockClearing() {
        let start = Date(timeIntervalSince1970: 1_790_330_000) // 2026-09-25T09:53:20Z
        var u = ClaudeUsage(processStart: start)
        let lines = [
            // Launched before this process (the session was resumed) and never finished.
            #"{"type":"assistant","timestamp":"2026-09-25T09:00:00.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"old","name":"Agent","input":{"description":"old","run_in_background":true}}],"usage":{}}}"#,
            #"{"type":"user","message":{"role":"user","content":"after resume"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-25T10:00:00.000Z","message":{"id":"m2","content":[{"type":"tool_use","id":"new","name":"Agent","input":{"description":"new"}}],"usage":{}}}"#,
        ]
        lines.forEach { u.ingest(line: $0) }
        #expect(u.subagents.map(\.id) == ["new"])
    }

    @Test func subagentActivityReadsLikeATerminal() {
        var a = SubagentActivity()
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Run `sleep 4`, then reply: done"}}"#,
            #"{"type":"assistant","message":{"model":"claude-haiku-4-5","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 4","description":"Sleep"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb\nc\nd\ne\nf\ng\nh"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/etc/hosts"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"denied"}]}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#,
        ]
        lines.forEach { a.ingest(line: $0) }
        #expect(a.model == "claude-haiku-4-5")
        #expect(a.entries == [
            .task("Run `sleep 4`, then reply: done"),
            .tool(id: "t1", name: "Bash", summary: "sleep 4", result: "a\nb\nc\nd\ne\nf\n… +2 lines", isError: false),
            .tool(id: "t2", name: "Read", summary: "/etc/hosts", result: "denied", isError: true),
            .text("done"),
        ])
    }

    @Test func lastUsedWindowFromClaudeJSON() {
        let json = Data(#"{"projects":{"/srv":{"lastModelUsage":{"claude-haiku-4-5":{},"claude-opus-5-5[1m]":{}}},"/old":{"lastModelUsage":{"claude-opus-5-5":{}}}}}"#.utf8)
        #expect(ClaudeUsage.lastUsedWindow(claudeJSON: json, folder: "/srv", model: "claude-opus-5-5") == 1_000_000)
        #expect(ClaudeUsage.lastUsedWindow(claudeJSON: json, folder: "/old", model: "claude-opus-5-5") == 200_000)
        #expect(ClaudeUsage.lastUsedWindow(claudeJSON: json, folder: "/none", model: "claude-opus-5-5") == nil)
    }

    @Test func snapshotPriority() {
        var t = ClaudeTranscriptState()
        t.aiTitle = "AI title"
        let rec = ClaudeSessionRecord(pid: 1, sessionId: "s", cwd: nil, status: "busy", name: "x-9f", nameSource: "derived")
        let snap = AgentSnapshot.make(record: rec, transcript: t, terminalTitle: (.idle, "osc title"))!
        #expect(snap.title == "AI title")
        #expect(snap.status == .busy) // the session file beats the title glyph
        t.customTitle = "Renamed"
        #expect(AgentSnapshot.make(record: rec, transcript: t, terminalTitle: nil)?.title == "Renamed")
        // Nothing but the terminal title (before the transcript exists).
        #expect(AgentSnapshot.make(record: nil, transcript: nil, terminalTitle: (.busy, "Ok"))?.title == "Ok")
        // Fresh session: only the placeholder title, so there is no real title yet.
        #expect(AgentSnapshot.make(record: rec, transcript: nil, terminalTitle: (.idle, "Claude Code"))?.title == nil)
        #expect(AgentSnapshot.make(record: nil, transcript: nil, terminalTitle: nil) == nil)
    }
}

@Suite struct ResumeCommandTests {
    func cmd(_ args: [String]) -> String {
        AgentSessionRef(sessionID: "9b4e-1", title: nil, arguments: args).resumeCommand
    }

    @Test func keepsFlagsAndAddsResume() {
        #expect(cmd(["claude", "--dangerously-skip-permissions"]) == "claude --dangerously-skip-permissions --resume 9b4e-1")
        #expect(cmd(["claude", "--model", "opus", "--add-dir", "/tmp/a b"]) == "claude --model opus --add-dir '/tmp/a b' --resume 9b4e-1")
    }

    @Test func dropsSessionPickersAndPrompts() {
        #expect(cmd(["claude", "--resume", "old-id", "--verbose"]) == "claude --verbose --resume 9b4e-1")
        #expect(cmd(["claude", "-r", "old", "-c", "--resume=x"]) == "claude --resume 9b4e-1")
        #expect(cmd(["claude", "--continue", "fix the bug"]) == "claude --resume 9b4e-1")
        #expect(cmd(["claude", "--resume"]) == "claude --resume 9b4e-1") // picker form, no value
    }

    @Test func versionedBinaryNameBecomesClaude() {
        #expect(cmd(["2.1.281", "--verbose"]) == "claude --verbose --resume 9b4e-1")
        #expect(cmd([]) == "claude --resume 9b4e-1")
    }

    @Test func persistsWithTab() throws {
        let ref = AgentSessionRef(sessionID: "s", title: "T", arguments: ["claude"])
        let tab = TerminalTab(agentSession: ref)
        let back = try JSONDecoder().decode(TerminalTab.self, from: JSONEncoder().encode(tab))
        #expect(back.agentSession == ref)
        // Layouts saved before this field existed still load.
        let old = #"{"id":"\#(UUID().uuidString)","autoTitle":"x"}"#
        #expect(try JSONDecoder().decode(TerminalTab.self, from: Data(old.utf8)).agentSession == nil)
    }
}

@Suite struct WaitingStatusTests {
    @Test func waitingComesFromTheSessionFile() throws {
        let json = #"{"pid":7,"sessionId":"s","status":"waiting","waitingFor":"input needed","name":"x","nameSource":"derived"}"#
        let rec = try JSONDecoder().decode(ClaudeSessionRecord.self, from: Data(json.utf8))
        #expect(rec.agentStatus == .waiting)
        // The title still shows the idle glyph; the record wins.
        let snap = AgentSnapshot.make(record: rec, transcript: nil, terminalTitle: (.idle, "Fix bug"))!
        #expect(snap.status == .waiting)
        #expect(snap.waitingFor == "input needed")
        #expect(snap.title == "Fix bug")
    }
}

@Suite struct TerminalImportTests {
    func c(_ tty: String, _ cwd: String?, _ kind: ImportCandidate.Kind, title: String? = nil) -> ImportCandidate {
        ImportCandidate(tty: tty, terminalWindowID: 1, terminalTabIndex: 1, cwd: cwd, customTitle: title, kind: kind)
    }
    let ref = AgentSessionRef(sessionID: "s", title: "T", arguments: ["claude"])

    @Test func groupsByFolderInFirstSeenOrder() {
        let cs = [c("a", "/x/api", .shell(runningCommand: nil)),
                  c("b", "/x/web", .tmux(session: "build-1")),
                  c("c", "/y/api", .claude(ref: ref, pid: 1, busy: false)),
                  c("d", nil, .shell(runningCommand: nil))]
        let g = TerminalImportPlan.groups(cs)
        #expect(g.map(\.name) == ["api", "web", "Imported"])
        #expect(g[0].members.map(\.tty) == ["a", "c"])
    }

    @Test func titlesAndDefaults() {
        #expect(c("a", "/x", .tmux(session: "build-x"), title: "tmux-open").tabTitle == "build-x")
        #expect(c("a", "/x", .shell(runningCommand: nil), title: "✳ Some AI title").tabTitle == nil)
        #expect(c("a", "/x", .shell(runningCommand: nil), title: "me@host:~").tabTitle == nil)
        #expect(c("a", "/x", .shell(runningCommand: nil), title: "deploy box").tabTitle == "deploy box")
        #expect(!c("a", "/x", .claude(ref: ref, pid: 1, busy: true)).selectedByDefault)
        #expect(c("a", "/x", .claude(ref: ref, pid: 1, busy: false)).selectedByDefault)
    }

    @Test func importReusesSameNamedGroup() {
        var w = WindowLayout()
        w.addTab(TerminalTab(autoTitle: "existing"))
        let first = w.importGroups([("web", [TerminalTab(autoTitle: "t1"), TerminalTab(autoTitle: "t2")])])
        #expect(first.count == 2)
        w.importGroups([("web", [TerminalTab(autoTitle: "t3")]), ("api", [TerminalTab(autoTitle: "t4")])])
        #expect(w.orderedGroups.map(\.name) == ["web", "api"])
        #expect(w.tabs(in: w.orderedGroups[0].id).map(\.autoTitle) == ["t1", "t2", "t3"])
        #expect(w.activeTab?.autoTitle == "existing") // import doesn't steal focus
        #expect(w.violations().isEmpty)
    }
}
