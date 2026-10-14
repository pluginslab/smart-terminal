import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct TmuxTests {
    @Test func parsesDisplayMessage() {
        let pane = TmuxPane.parse("lucas-acme\t%5\t38553\t✳ Add Stripe webhook retries\n")
        #expect(pane == TmuxPane(session: "lucas-acme", paneID: "%5", panePID: 38553, title: "✳ Add Stripe webhook retries"))
        // A title can contain tabs; it's the last field.
        #expect(TmuxPane.parse("s\t%1\t42\ta\tb")?.title == "a\tb")
        #expect(TmuxPane.parse("s\t%1\t42")?.title == "")
        #expect(TmuxPane.parse("") == nil)
        #expect(TmuxPane.parse("s\t%1\tnot-a-pid\tx") == nil)
    }

    @Test func socketArgsFromClientCommandLine() {
        #expect(TmuxSessionRef.socketArgs(fromClientArguments: ["tmux", "attach", "-t", "x"]) == [])
        #expect(TmuxSessionRef.socketArgs(fromClientArguments: ["tmux", "-L", "work", "attach", "-t", "x"]) == ["-L", "work"])
        #expect(TmuxSessionRef.socketArgs(fromClientArguments: ["tmux", "-S/tmp/my sock", "a"]) == ["-S", "/tmp/my sock"])
        #expect(TmuxSessionRef.socketArgs(fromClientArguments: ["tmux", "-2", "-u", "-L", "w", "new", "-s", "x"]) == ["-L", "w"])
        // Options after the command belong to it, not to the server.
        #expect(TmuxSessionRef.socketArgs(fromClientArguments: ["tmux", "new", "-L", "x"]) == [])
    }

    @Test func commands() {
        let t = TmuxSessionRef(session: "lucas-acme")
        #expect(t.attachCommand == "tmux attach -t lucas-acme")
        #expect(TmuxSessionRef(session: "my work", socketArgs: ["-L", "w"]).attachCommand == "tmux -L w attach -t 'my work'")
        let claude = AgentSessionRef(sessionID: "9b4e-1", title: "Fix", arguments: ["claude", "--dangerously-skip-permissions"],
                                     cwd: "/Users/me/my app")
        #expect(t.recreateCommand(cwd: claude.cwd, command: claude.resumeCommand) ==
                "tmux new-session -d -s lucas-acme -c '/Users/me/my app' && "
                + "tmux send-keys -t lucas-acme 'claude --dangerously-skip-permissions --resume 9b4e-1' Enter && "
                + "tmux attach -t lucas-acme")
        #expect(t.recreateCommand(cwd: nil, command: nil) == "tmux new-session -d -s lucas-acme && tmux attach -t lucas-acme")
    }

    @Test func recoveryPicksTheOffer() {
        let claude = AgentSessionRef(sessionID: "id", title: nil, arguments: ["claude"], cwd: "/claude/dir")
        let t = TmuxSessionRef(session: "s")
        #expect(TabRecovery.make(agent: nil, tmux: nil) { _ in true } == nil)
        #expect(TabRecovery.make(agent: claude, tmux: nil) { _ in true } == .resume(claude))
        #expect(TabRecovery.make(agent: claude, tmux: t) { _ in true } == .reattach(t, agent: claude))
        #expect(TabRecovery.make(agent: nil, tmux: t) { _ in false } == .recreate(t, agent: nil))
        // Recreated in Claude's folder, which `--resume` needs, not the tab's.
        let cmd = TabRecovery.recreate(t, agent: claude).command(cwd: "/tab/dir")
        #expect(cmd.contains("-c /claude/dir") && cmd.contains("--resume id"))
        #expect(TabRecovery.reattach(t, agent: claude).command(cwd: "/tab/dir") == "tmux attach -t s")
    }

    @Test func layoutsFromOlderVersionsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","autoTitle":"x","agentSession":{"sessionID":"a","arguments":["claude"]}}"#
        let tab = try JSONDecoder().decode(TerminalTab.self, from: Data(old.utf8))
        #expect(tab.tmuxSession == nil && tab.agentSession?.cwd == nil && tab.agentSession?.sessionID == "a")
        var t = tab
        t.tmuxSession = TmuxSessionRef(session: "s", socketArgs: ["-L", "w"])
        #expect(try JSONDecoder().decode(TerminalTab.self, from: JSONEncoder().encode(t)) == t)
    }
}
