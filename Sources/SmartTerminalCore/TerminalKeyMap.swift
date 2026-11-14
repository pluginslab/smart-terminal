import Foundation

/// Terminal.app's key bindings: a profile's `keyMapBoundKeys`, or Terminal's own
/// `keyMappings.plist` when the profile has none. Each one makes a key with modifiers
/// type a string. It is how Terminal.app makes ⌥← jump a word while Option still types
/// accents (Option isn't Meta by default), and how a profile adds more, such as ⌥⌫
/// deleting a word.
///
/// Only bindings with Option are kept. SwiftTerm already sends the same standard
/// sequences for the others (F-keys, ⇧← and ⌃←), and can encode those for a program
/// that asks for the kitty keyboard protocol; intercepting them would only get in the
/// way. With Option, SwiftTerm hands the key to the text system, which drops ⌥← and
/// ⌥⌫ and types π for ⌥P.
public struct TerminalKeyMap: Equatable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
    }

    struct Chord: Hashable, Sendable {
        var modifiers: Modifiers
        /// The key as `NSEvent.charactersIgnoringModifiers` gives it, first UTF-16 unit:
        /// 0x7F for ⌫, 0xF702 for ←, 0x70 for P.
        var key: UInt16
    }

    private var bindings: [Chord: [UInt8]] = [:]

    public init() {}

    /// `entries` as Terminal stores them: "~F702" → "\u{1B}b".
    public init(entries: [String: String]) {
        for (key, value) in entries {
            guard let chord = Self.chord(key), chord.modifiers.contains(.option),
                  let bytes = Self.text(value) else { continue }
            bindings[chord] = bytes
        }
    }

    public var isEmpty: Bool { bindings.isEmpty }
    public var count: Int { bindings.count }

    /// What the key sends, or nil to leave it to the terminal.
    public func bytes(modifiers: Modifiers, key: UInt16) -> [UInt8]? {
        bindings[Chord(modifiers: modifiers, key: key)]
    }

    /// What a key with Command alone sends, for the line shortcuts of a Mac text field:
    /// ⌘← and ⌘→ go to the start and end of the line, ⌘⌫ deletes back to its start and
    /// ⌘⌦ to its end. Terminal.app can't bind them (its key editor has no ⌘), and
    /// SwiftTerm hands them to the text system, which sends ⌘← and ⌘→ as a word jump
    /// and nothing for ⌘⌫. They go out as the Emacs keys that shells and line editors
    /// already know: ⌃A, ⌃E, ⌃U and ⌃K. iTerm2's "Natural Text Editing" preset sends the
    /// same for ⌘←, ⌘→ and ⌘⌫.
    public static func commandLineEditing(key: UInt16) -> [UInt8]? {
        switch key {
        case 0xF702: [0x01]  // ⌘←  ⌃A  start of line
        case 0xF703: [0x05]  // ⌘→  ⌃E  end of line
        case 0x7F: [0x15]    // ⌘⌫  ⌃U  delete to the start
        case 0xF728: [0x0B]  // ⌘⌦  ⌃K  delete to the end
        default: nil
        }
    }

    /// "~^F728": modifier prefixes (^ control, ~ option, $ shift), then the key as four
    /// hex digits. Keypad (#) and Command (@) bindings are left out: arrows always carry
    /// the keypad flag, so it can't tell them apart, and Terminal's editor can't bind ⌘.
    static func chord(_ string: String) -> Chord? {
        var modifiers: Modifiers = []
        var rest = Substring(string)
        while let c = rest.first, "^~$#@".contains(c) {
            switch c {
            case "^": modifiers.insert(.control)
            case "~": modifiers.insert(.option)
            case "$": modifiers.insert(.shift)
            default: return nil
            }
            rest = rest.dropFirst()
        }
        guard rest.count == 4, rest.allSatisfy(\.isHexDigit), let key = UInt16(rest, radix: 16) else { return nil }
        return Chord(modifiers: modifiers, key: key)
    }

    /// The bytes to send. Nil for an empty binding or an action, which Terminal stores
    /// as a selector ("toggleNumLock:").
    static func text(_ value: String) -> [UInt8]? {
        if value.isEmpty { return nil }
        let name = value.dropLast()
        if value.hasSuffix(":"), !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isLetter }) { return nil }
        return Array(value.utf8)
    }
}
