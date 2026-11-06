import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct TabHistoryTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func backAndForwardRetraceVisits() {
        var h = TabHistory()
        [a, b, c].forEach { h.visit($0) }
        let all: (UUID) -> Bool = { _ in true }
        #expect(!h.canMove(1, exists: all))
        #expect(h.move(-1, exists: all) == b)
        h.visit(b) // showing it records nothing new
        #expect(h.move(-1, exists: all) == a)
        #expect(!h.canMove(-1, exists: all))
        #expect(h.move(1, exists: all) == b)
        #expect(h.move(1, exists: all) == c)
    }

    @Test func aNewVisitDropsWhatWasAhead() {
        var h = TabHistory()
        [a, b, c].forEach { h.visit($0) }
        _ = h.move(-1, exists: { _ in true })
        h.visit(d)
        #expect(h.entries == [a, b, d] && !h.canMove(1, exists: { _ in true }))
    }

    @Test func goneTabsAndRepeatsAreSkipped() {
        var h = TabHistory()
        [a, b, a, c].forEach { h.visit($0) }
        // c is shown and b was closed: back reaches a; before it only b (gone) and a (shown).
        let open: (UUID) -> Bool = { $0 != b }
        #expect(h.move(-1, exists: open) == a)
        #expect(!h.canMove(-1, exists: open)) // b is gone, the a before it is the tab shown
    }

    @Test func historyIsCapped() {
        var h = TabHistory()
        for _ in 0..<(TabHistory.limit + 20) { h.visit(UUID()) }
        #expect(h.entries.count == TabHistory.limit && h.index == TabHistory.limit - 1)
    }
}
