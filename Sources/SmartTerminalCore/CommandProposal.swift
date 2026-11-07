import Foundation

/// A command Claude asks you to run: Smart Terminal opens a tab beside the session and
/// types it there, and you press Return. Nothing here runs anything.
///
/// So that only your Return runs it, the text typed must not be able to run itself or
/// look like something else: no line breaks (a newline is Return), no tab (completion),
/// no escape or other control characters (key sequences), no bidirectional overrides
/// (text that reads differently than it runs).
public enum CommandProposal {
    public static let maxLength = 4000

    /// Why `command` can't be typed for you, or nil when it can.
    public static func problem(with command: String) -> String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return "The command is empty." }
        if command.count > maxLength { return "The command is longer than \(maxLength) characters. Put it in a script and propose running that." }
        for scalar in command.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D:
                return "The command has a line break, which would run it before you see it. Join it into one line (with && or ;) or put it in a script."
            case 0x09:
                return "The command has a tab character, which the shell takes as completion. Use spaces."
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                return "The command has a control character (U+\(String(format: "%04X", scalar.value))). Only printable text can be typed for you."
            case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C:
                return "The command has a text-direction control (U+\(String(format: "%04X", scalar.value))), which can make it read differently than it runs."
            default:
                continue
            }
        }
        return nil
    }

    /// What the shell reports once the first command in the tab finished: the exit
    /// status on the first line, the command line as it ran on the rest (you may have
    /// edited it before pressing Return).
    public struct Outcome: Equatable, Sendable {
        public var exitCode: Int
        public var command: String
        public init(exitCode: Int, command: String) { self.exitCode = exitCode; self.command = command }
    }

    public static func parseOutcome(_ text: String) -> Outcome? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let code = Int(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let command = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .newlines) : ""
        return Outcome(exitCode: code, command: command)
    }

    /// What the command printed: the screen from the line where it was typed (the last
    /// one showing it), else the whole screen, at most `limit` lines.
    public static func output(_ lines: [String], command: String, limit: Int = 40) -> String {
        let probe = String(command.prefix(16)) // the start only: a long command wraps
        guard !probe.isEmpty, let i = lines.lastIndex(where: { $0.contains(probe) }) else { return tail(lines, limit: limit) }
        return tail(Array(lines[(i + 1)...]), limit: limit)
    }

    /// The last `limit` lines that have text, without the trailing blank ones.
    public static func tail(_ lines: [String], limit: Int = 40) -> String {
        var trimmed = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        return trimmed.suffix(limit).joined(separator: "\n")
    }
}
