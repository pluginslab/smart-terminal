import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct ClaudeSessionIndexTests {
    @Test func tabsAndSessionsCarryNameGroupAndColor() throws {
        var w = WindowLayout(tabs: [TerminalTab(customTitle: "api", cwd: "/x")])
        let api = w.tabs[0].id
        w.createGroup(with: api, name: "Apps", color: .blue)
        let loose = w.addTab(TerminalTab(customTitle: "notes"), nextToActive: false)
        let index = ClaudeSessionIndex(layout: AppLayout(windows: [WindowLayout(), w]),
                                       sessionIDs: [api: "sid-1"], pid: 42)
        let s = try #require(index.sessions["sid-1"])
        #expect(s.tab == "api" && s.window == 2 && s.cwd == "/x" && s.tabID == api.uuidString)
        #expect(s.group?.name == "Apps" && s.group?.color == "blue")
        #expect(index.tabs[api.uuidString] == s)
        let n = try #require(index.tabs[loose.id.uuidString])
        #expect(n.group == nil && n.sessionID == nil && index.sessions.count == 1)
    }

    @Test func writesAtomicallyAndPrivately() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("claude-sessions.json")
        let a = ClaudeSessionIndex(layout: AppLayout(windows: [WindowLayout(tabs: [TerminalTab()])]), sessionIDs: [:], pid: 1,
                                   now: Date(timeIntervalSince1970: 0))
        try a.write(to: url)
        try a.write(to: url) // replacing an existing file
        let back = try JSONDecoder().decode(ClaudeSessionIndex.self, from: Data(contentsOf: url))
        #expect(back == a && back.version == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        var later = a; later.updatedAt = "later"
        #expect(later.sameContent(as: a) && !later.sameContent(as: nil))
    }
}
