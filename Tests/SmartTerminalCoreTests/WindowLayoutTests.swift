import Foundation
import Testing
@testable import SmartTerminalCore

/// Builds a window from a compact spec: "a b [G: c d] e" — letters are tabs, brackets a group.
func make(_ spec: String) -> (WindowLayout, [String: UUID], [String: UUID]) {
    var tabs: [TerminalTab] = []
    var groups: [TabGroup] = []
    var tabIDs: [String: UUID] = [:]
    var groupIDs: [String: UUID] = [:]
    var current: UUID?
    for token in spec.split(separator: " ").map(String.init) {
        var tok = token
        if tok.hasPrefix("[") {
            let name = String(tok.dropFirst().dropLast()) // "[G:" -> "G"
            let g = TabGroup(name: name, color: .blue)
            groups.append(g); groupIDs[name] = g.id; current = g.id
            continue
        }
        var closes = false
        if tok.hasSuffix("]") { closes = true; tok.removeLast() }
        let t = TerminalTab(autoTitle: tok, groupID: current)
        tabs.append(t); tabIDs[tok] = t.id
        if closes { current = nil }
    }
    return (WindowLayout(tabs: tabs, groups: groups), tabIDs, groupIDs)
}

/// Renders a window back to the compact spec (collapsed groups shown with `-`).
func render(_ w: WindowLayout) -> String {
    var out: [String] = []
    var current: UUID?
    for t in w.tabs {
        if t.groupID != current {
            if current != nil { out[out.count - 1] += "]" }
            if let g = t.groupID { out.append("[\(w.group(g)!.name)\(w.group(g)!.isCollapsed ? "-" : ""):") }
            current = t.groupID
        }
        out.append(t.displayTitle)
    }
    if current != nil { out[out.count - 1] += "]" }
    return out.joined(separator: " ")
}

@Suite struct WindowLayoutTests {
    @Test func specRoundTrip() {
        let (w, _, _) = make("a b [G: c d] e")
        #expect(render(w) == "a b [G: c d] e")
        #expect(w.violations().isEmpty)
    }

    @Test func newTabGoesNextToActiveAndJoinsItsGroup() {
        var (w, t, _) = make("a [G: b c] d")
        w.select(t["b"]!)
        w.addTab(TerminalTab(autoTitle: "x"))
        #expect(render(w) == "a [G: b x c] d")
        #expect(w.activeTab?.displayTitle == "x")
    }

    @Test func newTabAtEndIsUngrouped() {
        var (w, t, _) = make("[G: a b]")
        w.select(t["a"]!)
        w.addTab(TerminalTab(autoTitle: "x"), nextToActive: false)
        #expect(render(w) == "[G: a b] x")
    }

    @Test func dropBetweenGroupTabsJoinsGroup() {
        var (w, t, _) = make("a [G: b c] d")
        w.move(tab: t["a"]!, to: .afterTab(t["b"]!))
        #expect(render(w) == "[G: b a c] d")
    }

    @Test func dropBeforeUngroupedTabLeavesGroup() {
        var (w, t, _) = make("a [G: b c] d")
        w.move(tab: t["c"]!, to: .beforeTab(t["d"]!))
        #expect(render(w) == "a [G: b] c d")
    }

    @Test func dropOntoChipAppendsToGroup() {
        var (w, t, g) = make("a [G: b c] d")
        w.move(tab: t["d"]!, to: .intoGroup(g["G"]!))
        #expect(render(w) == "a [G: b c d]")
    }

    @Test func dropBetweenTwoGroupsUngrouped() {
        var (w, t, g) = make("[G: a b] [H: c] d")
        w.move(tab: t["d"]!, to: .beforeGroup(g["H"]!))
        #expect(render(w) == "[G: a b] d [H: c]")
    }

    @Test func movingLastTabOutDeletesGroup() {
        var (w, t, g) = make("a [G: b]")
        w.move(tab: t["b"]!, to: .beforeTab(t["a"]!))
        #expect(render(w) == "b a")
        #expect(w.group(g["G"]!) == nil)
    }

    @Test func movingOnlyTabOfGroupIntoItsOwnChipKeepsGroup() {
        var (w, t, g) = make("a [G: b]")
        w.move(tab: t["b"]!, to: .intoGroup(g["G"]!))
        #expect(render(w) == "a [G: b]")
    }

    @Test func dropOnSelfIsNoop() {
        var (w, t, _) = make("a [G: b c]")
        let before = w
        w.move(tab: t["b"]!, to: .beforeTab(t["b"]!))
        #expect(w == before)
    }

    @Test func createGroupFromTabInsideAnotherGroupMovesItOut() {
        var (w, t, _) = make("[G: a b c] d")
        let h = w.createGroup(with: t["b"]!, name: "H")!
        #expect(render(w) == "[G: a c] [H: b] d")
        #expect(h.color != .blue || w.groups.count == 2)
        #expect(w.violations().isEmpty)
    }

    @Test func nextColorAvoidsUsedColors() {
        var (w, t, _) = make("a b c")
        let g1 = w.createGroup(with: t["a"]!)!
        let g2 = w.createGroup(with: t["b"]!)!
        #expect(g1.color != g2.color)
    }

    @Test func ungroupKeepsPositions() {
        var (w, _, g) = make("a [G: b c] d")
        w.ungroup(g["G"]!)
        #expect(render(w) == "a b c d")
        #expect(w.groups.isEmpty)
    }

    @Test func removeFromGroupPlacesTabAfterGroup() {
        var (w, t, _) = make("[G: a b c] d")
        w.removeFromGroup(tab: t["a"]!)
        #expect(render(w) == "[G: b c] a d")
    }

    @Test func closeGroupClosesItsTabs() {
        var (w, t, g) = make("a [G: b c] d")
        w.select(t["b"]!)
        let closed = w.closeGroup(g["G"]!)
        #expect(closed.count == 2)
        #expect(render(w) == "a d")
        #expect(w.activeTab?.displayTitle == "d")
    }

    @Test func closingActivePicksRightThenLeft() {
        var (w, t, _) = make("a b c")
        w.select(t["b"]!)
        w.removeTab(t["b"]!)
        #expect(w.activeTab?.displayTitle == "c")
        w.removeTab(t["c"]!)
        #expect(w.activeTab?.displayTitle == "a")
        w.removeTab(t["a"]!)
        #expect(w.activeTabID == nil)
        #expect(w.violations().isEmpty)
    }

    @Test func collapsingActiveGroupMovesSelectionOut() {
        var (w, t, g) = make("a [G: b c] d")
        w.select(t["b"]!)
        w.setCollapsed(g["G"]!, true)
        #expect(w.activeTab?.displayTitle == "d")
        #expect(w.visibleTabs.map(\.displayTitle) == ["a", "d"])
    }

    @Test func selectingHiddenTabExpandsGroup() {
        var (w, t, g) = make("a [G: b c]")
        w.setCollapsed(g["G"]!, true)
        w.select(t["c"]!)
        #expect(w.group(g["G"]!)?.isCollapsed == false)
    }

    @Test func stripItemsHideCollapsedTabs() {
        var (w, _, g) = make("a [G: b c] d")
        w.setCollapsed(g["G"]!, true)
        let kinds = w.stripItems.map { item -> String in
            switch item {
            case .chip(let grp, let n): "chip:\(grp.name):\(n)"
            case .tab(let tab): tab.displayTitle
            }
        }
        #expect(kinds == ["a", "chip:G:2", "d"])
    }

    @Test func selectNumberUsesVisibleTabsAndNineIsLast() {
        var (w, _, g) = make("a [G: b c] d e")
        w.setCollapsed(g["G"]!, true)
        w.selectNumber(2)
        #expect(w.activeTab?.displayTitle == "d")
        w.selectNumber(9)
        #expect(w.activeTab?.displayTitle == "e")
    }

    @Test func selectRelativeWraps() {
        var (w, t, _) = make("a b c")
        w.select(t["c"]!)
        w.selectRelative(1)
        #expect(w.activeTab?.displayTitle == "a")
        w.selectRelative(-1)
        #expect(w.activeTab?.displayTitle == "c")
    }

    @Test func renameAndClear() {
        var (w, t, _) = make("a")
        w.rename(tab: t["a"]!, to: "  api logs ")
        #expect(w.tab(t["a"]!)?.displayTitle == "api logs")
        w.rename(tab: t["a"]!, to: "   ")
        #expect(w.tab(t["a"]!)?.customTitle == nil)
        #expect(w.tab(t["a"]!)?.displayTitle == "a")
    }

    @Test func moveGroupBeforeTab() {
        var (w, t, g) = make("a b [G: c d] e")
        w.moveGroup(g["G"]!, to: .beforeTab(t["a"]!))
        #expect(render(w) == "[G: c d] a b e")
    }

    @Test func moveGroupIntoAnotherGroupSnapsToItsStart() {
        var (w, t, g) = make("[H: a b c] [G: d]")
        w.moveGroup(g["G"]!, to: .afterTab(t["a"]!))
        #expect(render(w) == "[G: d] [H: a b c]")
    }

    @Test func moveGroupToEnd() {
        var (w, _, g) = make("[G: a b] c")
        w.moveGroup(g["G"]!, to: .end)
        #expect(render(w) == "c [G: a b]")
    }

    @Test func updateTabCannotChangeGroupMembership() {
        var (w, t, _) = make("a [G: b]")
        let g = w.tabs[1].groupID
        w.updateTab(t["a"]!) { $0.groupID = g; $0.autoTitle = "z" }
        #expect(render(w) == "z [G: b]")
    }

    @Test func codableRoundTrip() throws {
        var (w, t, g) = make("a [G: b c] d")
        w.setCollapsed(g["G"]!, true)
        w.rename(tab: t["a"]!, to: "custom")
        w.frame = WindowFrame(x: 1, y: 2, width: 800, height: 600)
        let data = try JSONEncoder().encode(AppLayout(windows: [w]))
        let back = try JSONDecoder().decode(AppLayout.self, from: data)
        #expect(back.windows == [w])
    }
}

@Suite struct AppLayoutTests {
    @Test func moveTabAcrossWindows() {
        let (w1, t1, _) = make("a b")
        let (w2, t2, g2) = make("[G: x y]")
        var app = AppLayout(windows: [w1, w2])
        let emptied = app.moveTab(t1["a"]!, toWindow: w2.id, at: .afterTab(t2["x"]!))
        #expect(emptied == nil)
        #expect(render(app.windows[0]) == "b")
        #expect(render(app.windows[1]) == "[G: x a y]")
        #expect(app.windows[1].activeTabID == t1["a"]!)
        #expect(app.windows[1].tab(t1["a"]!)?.groupID == g2["G"]!)
    }

    @Test func movingLastTabReportsEmptiedWindow() {
        let (w1, t1, _) = make("a")
        let (w2, _, _) = make("x")
        var app = AppLayout(windows: [w1, w2])
        #expect(app.moveTab(t1["a"]!, toWindow: w2.id, at: .end) == w1.id)
    }

    @Test func moveGroupAcrossWindowsKeepsIdentity() {
        let (w1, _, g1) = make("a [G: b c]")
        let (w2, t2, _) = make("x")
        var app = AppLayout(windows: [w1, w2])
        app.moveGroup(g1["G"]!, toWindow: w2.id, at: .beforeTab(t2["x"]!))
        #expect(render(app.windows[0]) == "a")
        #expect(render(app.windows[1]) == "[G: b c] x")
        #expect(app.windows[1].group(g1["G"]!) != nil)
    }

    @Test func detachTabAndGroup() {
        let (w1, t1, g1) = make("a [G: b c] d")
        var app = AppLayout(windows: [w1])
        let r1 = app.detachTab(t1["a"]!)!
        #expect(app.windows.count == 2)
        #expect(render(app.windows[1]) == "a")
        #expect(r1.emptied == nil)
        let r2 = app.detachGroup(g1["G"]!)!
        #expect(render(app.window(r2.newWindow)!) == "[G: b c]")
        #expect(render(app.windows[0]) == "d")
    }

    @Test func detachOnlyTabIsRefused() {
        let (w1, t1, _) = make("a")
        var app = AppLayout(windows: [w1])
        #expect(app.detachTab(t1["a"]!) == nil)
    }

    @Test func storeRoundTripAndCorruptFileIsSetAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LayoutStore(url: dir.appendingPathComponent("layout.json"))
        #expect(store.load() == nil)
        let (w, _, _) = make("a [G: b]")
        try store.save(AppLayout(windows: [w, WindowLayout()]))
        #expect(store.load()?.windows == [w]) // empty windows are not persisted
        try Data("nope".utf8).write(to: store.url)
        #expect(store.load() == nil)
        #expect(FileManager.default.fileExists(atPath: store.url.path + ".corrupt"))
    }
}

/// Throws random operations at a multi-window layout and checks invariants after each.
@Suite struct FuzzTests {
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state
        }
    }

    @Test(arguments: 1...20)
    func randomOperationsKeepInvariants(seed: Int) {
        var rng = RNG(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1)
        var app = AppLayout(windows: [WindowLayout(), WindowLayout()])
        for _ in 0..<5 { app.windows[0].addTab(); app.windows[1].addTab() }

        func randomTarget(in w: WindowLayout) -> DropTarget {
            let tabIDs = w.tabs.map(\.id), groupIDs = Array(w.groups.keys)
            switch Int.random(in: 0..<6, using: &rng) {
            case 0 where !tabIDs.isEmpty: return .beforeTab(tabIDs.randomElement(using: &rng)!)
            case 1 where !tabIDs.isEmpty: return .afterTab(tabIDs.randomElement(using: &rng)!)
            case 2 where !groupIDs.isEmpty: return .intoGroup(groupIDs.randomElement(using: &rng)!)
            case 3 where !groupIDs.isEmpty: return .beforeGroup(groupIDs.randomElement(using: &rng)!)
            case 4 where !groupIDs.isEmpty: return .afterGroup(groupIDs.randomElement(using: &rng)!)
            default: return .end
            }
        }

        let totalTabs = { app.windows.reduce(0) { $0 + $1.tabs.count } }
        var expectedTotal = totalTabs()

        for step in 0..<400 {
            let wi = Int.random(in: 0..<app.windows.count, using: &rng)
            let w = app.windows[wi]
            let anyTab = w.tabs.randomElement(using: &rng)?.id
            let anyGroup = w.groups.keys.randomElement(using: &rng)
            let other = app.windows.randomElement(using: &rng)!

            switch Int.random(in: 0..<12, using: &rng) {
            case 0: app.windows[wi].addTab(); expectedTotal += 1
            case 1: if let t = anyTab, w.tabs.count > 1 { app.windows[wi].removeTab(t); expectedTotal -= 1 }
            case 2: if let t = anyTab { app.windows[wi].move(tab: t, to: randomTarget(in: w)) }
            case 3: if let t = anyTab { app.windows[wi].createGroup(with: t) }
            case 4: if let g = anyGroup { app.windows[wi].toggleCollapsed(g) }
            case 5: if let g = anyGroup { app.windows[wi].ungroup(g) }
            case 6: if let t = anyTab { app.windows[wi].removeFromGroup(tab: t) }
            case 7: if let g = anyGroup { app.windows[wi].moveGroup(g, to: randomTarget(in: w)) }
            case 8:
                if let t = anyTab, let e = app.moveTab(t, toWindow: other.id, at: randomTarget(in: other)) {
                    app.removeWindow(e)
                }
            case 9:
                if let g = anyGroup, let e = app.moveGroup(g, toWindow: other.id, at: randomTarget(in: other)) {
                    app.removeWindow(e)
                }
            case 10: if let t = anyTab { app.windows[wi].select(t) }
            default: app.windows[wi].selectRelative(Int.random(in: -3...3, using: &rng))
            }

            for win in app.windows {
                let v = win.violations()
                #expect(v.isEmpty, "seed \(seed) step \(step): \(v) in \(render(win))")
                if !v.isEmpty { return }
            }
            #expect(totalTabs() == expectedTotal, "seed \(seed) step \(step): tab count drifted")
            if app.windows.count < 2 { app.windows.append(WindowLayout()); app.windows[app.windows.count - 1].addTab(); expectedTotal += 1 }
        }
    }
}

@Suite struct ShellTitleTests {
    let locals = ["Alexs-MacBook-Pro.local", "Alex’s MacBook Pro"]

    @Test func localPromptIsNoise() {
        #expect(ShellTitle.classify("alex@Alexs-MacBook-Pro:~", localHostNames: locals) == .localPrompt)
        #expect(ShellTitle.classify("me@localhost:/tmp", localHostNames: locals) == .localPrompt)
    }

    @Test func remotePromptKeepsHost() {
        #expect(ShellTitle.classify("root@buildbox: ~/servers", localHostNames: locals)
                == .remote(host: "buildbox", path: "~/servers"))
        #expect(ShellTitle.classify("deploy@web1.example.com:", localHostNames: locals)
                == .remote(host: "web1", path: "~"))
    }

    @Test func otherTitlesAreCustom() {
        #expect(ShellTitle.classify("vim README.md", localHostNames: locals) == .custom("vim README.md"))
        #expect(ShellTitle.classify("mail me@x.com: hi", localHostNames: locals) == .custom("mail me@x.com: hi"))
        #expect(ShellTitle.classify("  ", localHostNames: locals) == nil)
    }
}

@Suite struct ShiftTests {
    @Test func shiftsWithinGroup() {
        var (w, t, _) = make("a [G: b c d] e")
        do { let moved = w.shift(tab: t["c"]!, by: -1); #expect(moved) }
        #expect(render(w) == "a [G: c b d] e")
        do { let moved = w.shift(tab: t["c"]!, by: 1); #expect(moved) }
        #expect(render(w) == "a [G: b c d] e")
    }

    @Test func stopsAtGroupEdges() {
        var (w, t, _) = make("a [G: b c] d")
        do { let moved = w.shift(tab: t["b"]!, by: -1); #expect(!moved) }
        do { let moved = w.shift(tab: t["c"]!, by: 1); #expect(!moved) }
        #expect(render(w) == "a [G: b c] d")
    }

    @Test func ungroupedTabsDoNotJumpIntoGroups() {
        var (w, t, _) = make("a b [G: c] d")
        do { let moved = w.shift(tab: t["a"]!, by: 1); #expect(moved) }
        #expect(render(w) == "b a [G: c] d")
        do { let moved = w.shift(tab: t["a"]!, by: 1); #expect(!moved) }
        do { let moved = w.shift(tab: t["d"]!, by: -1); #expect(!moved) }
    }
}
