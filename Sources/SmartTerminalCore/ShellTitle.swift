import Foundation

/// What a shell-set window title (OSC 0/2) tells us.
public enum ShellTitle: Equatable, Sendable {
    /// "user@thismac:path": noise, the cwd already says it.
    case localPrompt
    /// "user@server:path": worth showing, the host is the point (ssh).
    case remote(host: String, path: String)
    /// Anything else a program chose (vim, htop, claude…).
    case custom(String)

    /// Returns nil for an empty title.
    public static func classify(_ raw: String, localHostNames: [String]) -> ShellTitle? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard let at = t.firstIndex(of: "@"), let colon = t[at...].firstIndex(of: ":"),
              !t[..<at].contains(" "), !t[at..<colon].contains(" ") else { return .custom(t) }
        let host = String(t[t.index(after: at)..<colon])
        let path = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let hostShort = host.components(separatedBy: ".").first ?? host
        let locals = localHostNames.flatMap { name -> [String] in
            let short = name.components(separatedBy: ".").first ?? name
            return [short, short.replacingOccurrences(of: " ", with: "-")]
        } + ["localhost"]
        if locals.contains(where: { $0.caseInsensitiveCompare(hostShort) == .orderedSame }) {
            return .localPrompt
        }
        return .remote(host: hostShort, path: path.isEmpty ? "~" : path)
    }
}
