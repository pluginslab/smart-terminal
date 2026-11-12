import Testing
@testable import SmartTerminalCore

@Suite struct TerminalKeyMapTests {
    private let esc = "\u{1B}"

    @Test func parsesModifiersAndKey() {
        #expect(TerminalKeyMap.chord("~007F") == TerminalKeyMap.Chord(modifiers: [.option], key: 0x7F))
        #expect(TerminalKeyMap.chord("~^F728") == TerminalKeyMap.Chord(modifiers: [.option, .control], key: 0xF728))
        #expect(TerminalKeyMap.chord("$~F702") == TerminalKeyMap.Chord(modifiers: [.option, .shift], key: 0xF702))
        #expect(TerminalKeyMap.chord("F708") == TerminalKeyMap.Chord(modifiers: [], key: 0xF708))
    }

    @Test func rejectsKeypadCommandAndMalformedKeys() {
        #expect(TerminalKeyMap.chord("#F704") == nil)
        #expect(TerminalKeyMap.chord("@~0070") == nil)
        #expect(TerminalKeyMap.chord("~F70") == nil)
        #expect(TerminalKeyMap.chord("~F7020") == nil)
        #expect(TerminalKeyMap.chord("~ZZZZ") == nil)
        #expect(TerminalKeyMap.chord("~+70A") == nil)
        #expect(TerminalKeyMap.chord("") == nil)
    }

    @Test func textSkipsActionsAndEmptyBindings() {
        #expect(TerminalKeyMap.text("toggleNumLock:") == nil)
        #expect(TerminalKeyMap.text("") == nil)
        #expect(TerminalKeyMap.text(esc + "b") == [0x1B, 0x62])
        #expect(TerminalKeyMap.text(esc + "\u{7F}") == [0x1B, 0x7F])
        #expect(TerminalKeyMap.text("é") == [0xC3, 0xA9])
        // A colon that isn't the end of a selector is text.
        #expect(TerminalKeyMap.text(":") == [0x3A])
        #expect(TerminalKeyMap.text(esc + ":") == [0x1B, 0x3A])
    }

    /// Terminal's defaults, abridged: only the Option bindings stay.
    @Test func keepsOnlyOptionBindings() {
        let map = TerminalKeyMap(entries: [
            "~F702": esc + "b",
            "~F703": esc + "f",
            "~^F728": esc + esc + "[3;5~",
            "$F702": esc + "[1;2D",
            "^F702": esc + "[1;5D",
            "F708": esc + "[15~",
            "#F739": "toggleNumLock:",
        ])
        #expect(map.count == 3)
        #expect(map.bytes(modifiers: [.option], key: 0xF702) == [0x1B, 0x62])
        #expect(map.bytes(modifiers: [.option, .control], key: 0xF728) == Array((esc + esc + "[3;5~").utf8))
        #expect(map.bytes(modifiers: [.shift], key: 0xF702) == nil)
        #expect(map.bytes(modifiers: [], key: 0xF708) == nil)
    }

    /// A profile that adds word deletion and Meta letters on top of the defaults.
    @Test func looksUpExactChords() {
        let map = TerminalKeyMap(entries: [
            "~007F": esc + "\u{7F}",
            "~F728": esc + "d",
            "~0070": esc + "p",
            "~0074": "",
        ])
        #expect(map.bytes(modifiers: [.option], key: 0x7F) == [0x1B, 0x7F])
        #expect(map.bytes(modifiers: [.option], key: 0xF728) == [0x1B, 0x64])
        #expect(map.bytes(modifiers: [.option], key: 0x70) == [0x1B, 0x70])
        // Extra modifiers make it another chord, and an empty binding is no binding.
        #expect(map.bytes(modifiers: [.option, .shift], key: 0x70) == nil)
        #expect(map.bytes(modifiers: [], key: 0x7F) == nil)
        #expect(map.bytes(modifiers: [.option], key: 0x74) == nil)
    }

    @Test func emptyByDefault() {
        #expect(TerminalKeyMap().isEmpty)
        #expect(TerminalKeyMap(entries: ["$F702": esc + "[1;2D"]).isEmpty)
    }
}
