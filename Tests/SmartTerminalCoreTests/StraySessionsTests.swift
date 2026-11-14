import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct StraySessionsTests {
    private func session(_ name: String, at t: TimeInterval = 0, attached: Int = 0) -> RemoteTmuxSession {
        RemoteTmuxSession(name: name, activity: Date(timeIntervalSince1970: t), attached: attached, path: "/home/p")
    }

    @Test func parsesListSessions() {
        let out = "1794668927\t0\t/home/pluginslab/codeable\tCandH\n"
            + "1794669151\t1\t/home/pluginslab\tipad-1\n"
            + "not-a-time\t0\t/x\tbroken\n"
            + "1794669151\t0\t/x\t\n"
            + "1794669558\t2\t/tmp\tname\twith tab\n"
        let s = RemoteTmuxSession.parse(out)
        #expect(s.map(\.name) == ["CandH", "ipad-1", "name\twith tab"])
        #expect(s[0] == RemoteTmuxSession(name: "CandH", activity: Date(timeIntervalSince1970: 1794668927),
                                          attached: 0, path: "/home/pluginslab/codeable"))
        #expect(s[1].attached == 1)
        #expect(RemoteTmuxSession.parse("").isEmpty)
    }

    @Test func displayPath() {
        #expect(session("a").displayPath == "~")
        var s = session("a")
        s.path = "/home/pluginslab/codeable/x"
        #expect(s.displayPath == "~/codeable/x")
        s.path = "/tmp/x"
        #expect(s.displayPath == "/tmp/x")
        s.path = "/home"
        #expect(s.displayPath == "/home")
    }

    @Test func firstListingAdoptsEverything() {
        var ledger = StrayLedger()
        #expect(ledger.reconcile(listed: [session("mac"), session("winix")], adoptedByTabs: []).isEmpty)
        #expect(ledger.migrated)
        #expect(ledger.adopted == ["mac", "winix"])
        // Sessions started after that are stray, newest first.
        let strays = ledger.reconcile(listed: [session("mac"), session("winix"), session("ipad-1", at: 5),
                                               session("script", at: 9)], adoptedByTabs: [])
        #expect(strays.map(\.name) == ["script", "ipad-1"])
    }

    @Test func groupedTabsAndKeepingAdopt() {
        var ledger = StrayLedger(migrated: true)
        let listed = [session("a"), session("b"), session("c")]
        // A tab in a group adopts its session, and it stays adopted after the tab leaves.
        #expect(ledger.reconcile(listed: listed, adoptedByTabs: ["b"]).map(\.name) == ["a", "c"])
        #expect(ledger.reconcile(listed: listed, adoptedByTabs: []).map(\.name) == ["a", "c"])
        // Keep in Ungrouped.
        let added = ledger.adopt(["a"]), again = ledger.adopt(["a"])
        #expect(added && !again)
        #expect(ledger.reconcile(listed: listed, adoptedByTabs: []).map(\.name) == ["c"])
    }

    /// Opening a stray in an ungrouped tab doesn't adopt it; putting the tab in a group does.
    @Test func onlyGroupedTabsAdopt() {
        var open = TerminalTab()
        open.remoteSession = StraySessions.attachRef("ipad-1")
        #expect(StraySessions.sessions(of: open, live: [:]) == ["ipad-1"])
        #expect(StraySessions.groupedSessions([open], live: [:]).isEmpty)
        var grouped = open
        grouped.groupID = UUID()
        #expect(StraySessions.groupedSessions([grouped], live: [:]) == ["ipad-1"])
        // The live ssh client counts too, and other hosts don't.
        var plain = TerminalTab(groupID: UUID())
        let live = [plain.id: RemoteSessionRef(arguments: ["ssh", "supermaschine-lan", "-t", "tmux new -A -s mac"])]
        #expect(StraySessions.groupedSessions([plain], live: live) == ["mac"])
        plain.remoteSession = RemoteSessionRef(arguments: ["ssh", "megamaschine", "-t", "tmux a -t x"])
        #expect(StraySessions.groupedSessions([plain], live: [:]).isEmpty)

        var ledger = StrayLedger(migrated: true)
        let listed = [session("ipad-1")]
        let whileOpen = ledger.reconcile(listed: listed, adoptedByTabs: StraySessions.groupedSessions([open], live: [:]))
        let onceGrouped = ledger.reconcile(listed: listed, adoptedByTabs: StraySessions.groupedSessions([grouped], live: [:]))
        #expect(whileOpen.count == 1)
        #expect(onceGrouped.isEmpty)
    }

    @Test func forgetsSessionsGoneFromTheHost() {
        var ledger = StrayLedger(migrated: true, adopted: ["old", "kept"])
        _ = ledger.reconcile(listed: [session("kept")], adoptedByTabs: ["elsewhere"])
        #expect(ledger.adopted == ["kept"])
        // A new session reusing the name is new.
        #expect(ledger.reconcile(listed: [session("kept"), session("old")], adoptedByTabs: []).map(\.name) == ["old"])
    }

    @Test func ledgerRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("stray-sessions.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(StrayLedger.load(from: url) == nil)
        let ledger = StrayLedger(migrated: true, adopted: ["mac", "x y"])
        try ledger.save(to: url)
        #expect(StrayLedger.load(from: url) == ledger)
    }

    @Test func host() {
        #expect(StraySessions.isHost("supermaschine"))
        #expect(StraySessions.isHost("supermaschine-lan"))
        #expect(StraySessions.isHost("supermaschine.tail1234.ts.net"))
        #expect(!StraySessions.isHost("megamaschine"))
        #expect(!StraySessions.isHost(nil))
    }

    /// The tab's command must read as a cc-super tab, so it gets Reconnect and counts as adopted.
    @Test func attachCommandIsARemoteTmuxTab() {
        let ref = StraySessions.attachRef("ipad-1")
        let parsed = RemoteSessionRef.from(sshArguments: ref.arguments)
        #expect(parsed == ref)
        #expect(ref.host == "supermaschine")
        #expect(ref.session == "ipad-1")
        #expect(TabRecovery.make(agent: nil, tmux: nil, remote: ref) { _ in false } == .reconnect(ref))
        #expect(ref.command == "ssh supermaschine -t 'tmux new-session -A -s ipad-1 '\\''cd ~/codeable && claude --dangerously-skip-permissions'\\'''")
        // A name the remote shell would split is quoted.
        #expect(StraySessions.attachRef("a b").arguments.last?.hasPrefix("tmux new-session -A -s 'a b' ") == true)
    }

    @Test func listArguments() {
        let args = StraySessions.listArguments(controlPath: "/c/%C")
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ConnectTimeout=5"))
        #expect(args.contains("ControlPath=/c/%C"))
        #expect(args.suffix(2) == ["supermaschine", "tmux list-sessions -F '\(RemoteTmuxSession.format)'"])
    }
}
