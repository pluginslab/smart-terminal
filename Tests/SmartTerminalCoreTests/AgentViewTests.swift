import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct AgentViewTests {
    let sessions = [
        BackgroundSessionRecord(pid: 101, sessionId: "3aa6a23e-b52f", cwd: "/repo/my-conf",
                                name: "mac option backspace shortcuts", jobId: "3aa6a23e"),
        BackgroundSessionRecord(pid: 102, sessionId: "dd16b711-012e", cwd: "/repo/jarvis/.claude/worktrees/x",
                                name: "check-jarvis-status", jobId: "dd16b711"),
        BackgroundSessionRecord(pid: 103, sessionId: "a7a85812-da3c", name: "claude", jobId: "a7a85812"),
        BackgroundSessionRecord(pid: 104, sessionId: "20cde62a-5f96", name: "claude", jobId: "20cde62a"),
        // An interactive session's file: not the daemon's.
        BackgroundSessionRecord(pid: 105, sessionId: "e1-interactive", name: "check-jarvis-status", kind: "interactive"),
    ]
    let list = AgentViewRef()
    var conf: AgentViewRef { AgentViewRef(jobID: "3aa6a23e", sessionID: "3aa6a23e-b52f",
                                          name: "mac option backspace shortcuts", cwd: "/repo/my-conf") }

    @Test func listTitle() {
        #expect(AgentViewTitle.isList("claude agents"))
        #expect(AgentViewTitle.isList("94 awaiting input · claude agents"))
        #expect(!AgentViewTitle.isList("✳ check-jarvis-status"))
        #expect(!AgentViewTitle.isList("claude"))
    }

    @Test func commands() {
        #expect(list.command == "claude agents")
        #expect(conf.command == "claude attach 3aa6a23e")
        // Typed into a shell: quoted, whatever the file said.
        #expect(AgentViewRef(jobID: "x; rm -rf ~").command == "claude attach 'x; rm -rf ~'")
    }

    /// Plain `claude` that opens the agent view, as in a setup where that's the default.
    @Test func followsTheListAndTheAttachedSession() {
        var t = AgentViewTracker()
        var reads = 0
        let read: () -> [BackgroundSessionRecord] = { reads += 1; return sessions }
        // The shell's title is still up: nothing known yet, and `claude` alone may be anything.
        #expect(t.update(pid: 7, arguments: ["claude"], title: "~/jarvis", sessions: read) == nil)
        #expect(t.update(pid: 7, arguments: [], title: "claude agents", sessions: read) == list)
        // A busy session attached: its spinner frames name it; the files are read once.
        #expect(t.update(pid: 7, arguments: [], title: "◐ mac option backspace shortcuts", sessions: read) == conf)
        #expect(t.update(pid: 7, arguments: [], title: "◓ mac option backspace shortcuts", sessions: read) == conf)
        #expect(t.update(pid: 7, arguments: [], title: "✳ mac option backspace shortcuts", sessions: read) == conf)
        #expect(reads == 1)
        // ← back to the list.
        #expect(t.update(pid: 7, arguments: [], title: "3 awaiting input · claude agents", sessions: read) == list)
        // Back on the same session after the list: looked up again.
        #expect(t.update(pid: 7, arguments: [], title: "✳ mac option backspace shortcuts", sessions: read) == conf)
        #expect(reads == 2)
    }

    @Test func aSessionItCannotNameComesBackAsTheList() {
        var t = AgentViewTracker()
        _ = t.update(pid: 7, arguments: ["claude", "agents"], title: "zsh", sessions: { sessions })
        // Two sessions have the title "claude": either could be open.
        #expect(t.update(pid: 7, arguments: [], title: "◐ claude", sessions: { sessions }) == list)
        // No session by that name (it ended, or the title isn't its name).
        #expect(t.update(pid: 7, arguments: [], title: "✳ Something else", sessions: { sessions }) == list)
        // Only background sessions count: the interactive file with the same name doesn't make it ambiguous.
        #expect(t.update(pid: 7, arguments: [], title: "✳ check-jarvis-status", sessions: { sessions })?.jobID == "dd16b711")
    }

    @Test func aTitleLeftByAnEarlierClientDoesNotCount() {
        var t = AgentViewTracker()
        #expect(t.update(pid: 7, arguments: ["claude", "agents"], title: "claude agents", sessions: { sessions }) == list)
        _ = t.update(pid: 7, arguments: [], title: "✳ mac option backspace shortcuts", sessions: { sessions })
        // That client exits; a new one opens the list while the old title is still up.
        #expect(t.update(pid: 8, arguments: ["claude", "agents"], title: "✳ mac option backspace shortcuts",
                         sessions: { sessions }) == list)
        // Its own title counts.
        #expect(t.update(pid: 8, arguments: [], title: "✳ check-jarvis-status", sessions: { sessions })?.jobID == "dd16b711")
    }

    @Test func attachArgumentsNameTheSessionBeforeAnyTitle() {
        // Attaching to an idle session sets no title: argv is all there is.
        var t = AgentViewTracker()
        #expect(t.update(pid: 9, arguments: ["claude", "attach", "3aa6a23e"], title: "zsh", sessions: { sessions }) == conf)
        // By a name only one session has.
        var u = AgentViewTracker()
        #expect(u.update(pid: 9, arguments: ["claude", "attach", "check-jarvis-status"], title: nil,
                         sessions: { sessions })?.jobID == "dd16b711")
        // An id whose session isn't running yet (attach starts a stopped one again).
        var v = AgentViewTracker()
        #expect(v.update(pid: 9, arguments: ["claude", "attach", "0151fcbe"], title: nil, sessions: { [] })
                == AgentViewRef(jobID: "0151fcbe"))
        // Part of a name: not something to type again later.
        var w = AgentViewTracker()
        #expect(w.update(pid: 9, arguments: ["claude", "attach", "jarvis"], title: nil, sessions: { sessions }) == list)
    }

    @Test func otherClaudesWithoutASessionFileAreNotTheAgentView() {
        var t = AgentViewTracker()
        #expect(t.update(pid: 7, arguments: ["claude", "-p", "summarize"], title: "zsh", sessions: { sessions }) == nil)
        #expect(t.update(pid: 7, arguments: [], title: "◐ claude", sessions: { sessions }) == nil)
    }

    @Test func recoveryAndLayout() throws {
        #expect(TabRecovery.make(agent: nil, tmux: nil, agentView: conf) { _ in true } == .attach(conf))
        #expect(TabRecovery.attach(conf).command(cwd: "/tab") == "claude attach 3aa6a23e")
        #expect(TabRecovery.attach(conf).agent == nil)
        // A Claude session of the tab's own wins (the two never come together, but if they did).
        let claude = AgentSessionRef(sessionID: "s", title: nil, arguments: ["claude"])
        #expect(TabRecovery.make(agent: claude, tmux: nil, agentView: conf) { _ in true } == .resume(claude))
        let tab = TerminalTab(agentView: conf)
        #expect(try JSONDecoder().decode(TerminalTab.self, from: JSONEncoder().encode(tab)).agentView == conf)
        // Layouts from before the field (or from the release build sharing the file) still load.
        let old = #"{"id":"\#(UUID().uuidString)","autoTitle":"x"}"#
        #expect(try JSONDecoder().decode(TerminalTab.self, from: Data(old.utf8)).agentView == nil)
    }

    @Test func recordsFromClaudeCodesFile() throws {
        let file = #"{"pid":35055,"sessionId":"0151fcbe-31f4","cwd":"/w","startedAt":1794607487192,"kind":"bg","name":"my-conf system health sweep","agent":"claude","jobId":"0151fcbe","status":"shell"}"#
        let r = try JSONDecoder().decode(BackgroundSessionRecord.self, from: Data(file.utf8))
        #expect(r.isBackground && r.jobId == "0151fcbe" && r.name == "my-conf system health sweep")
        let interactive = #"{"pid":1,"sessionId":"x","cwd":"/w","kind":"interactive"}"#
        #expect(try !JSONDecoder().decode(BackgroundSessionRecord.self, from: Data(interactive.utf8)).isBackground)
    }
}
