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
