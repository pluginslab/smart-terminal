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

    @Test func groupsAndTabsCarryTheirSidebarOrder() throws {
        var w = WindowLayout(tabs: [TerminalTab(customTitle: "a")])
        let a = w.tabs[0].id
        w.createGroup(with: a, name: "First", color: .blue)
        let b = w.addTab(TerminalTab(customTitle: "b"), nextToActive: false)
        w.createGroup(with: b.id, name: "Second", color: .green)
        let index = ClaudeSessionIndex(layout: AppLayout(windows: [w]), sessionIDs: [:], pid: 1)
        let ta = try #require(index.tabs[a.uuidString]), tb = try #require(index.tabs[b.id.uuidString])
        let order = Dictionary(uniqueKeysWithValues: w.orderedGroups.enumerated().map { ($0.element.name, $0.offset) })
        #expect(ta.group?.order == order["First"] && tb.group?.order == order["Second"])
        #expect(Set([ta.group?.order, tb.group?.order]) == [0, 1])
        let tabOrder = Dictionary(uniqueKeysWithValues: w.tabs.enumerated().map { ($0.element.id, $0.offset) })
        #expect(ta.order == tabOrder[a] && tb.order == tabOrder[b.id] && Set([ta.order, tb.order]) == [0, 1])
        // Always in the JSON, and kept by a round trip.
        let data = try JSONEncoder().encode(index)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let raw = try #require((json["tabs"] as? [String: Any])?[a.uuidString] as? [String: Any])
        #expect(raw["order"] as? Int == ta.order && (raw["group"] as? [String: Any])?["order"] as? Int == ta.group?.order)
        #expect(try JSONDecoder().decode(ClaudeSessionIndex.self, from: data) == index)
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
