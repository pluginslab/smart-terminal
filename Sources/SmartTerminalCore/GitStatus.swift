import Foundation

/// A working copy's state, as a tab's row shows it: branch, how far it is from
/// its upstream, and the uncommitted diff.
public struct GitStatus: Equatable, Sendable {
    /// Branch name; nil when HEAD is detached.
    public var branch: String?
    /// Short commit id, for a detached HEAD.
    public var commit: String?
    public var hasUpstream = false
    public var ahead = 0
    public var behind = 0
    /// Tracked files with staged or unstaged changes, conflicts included.
    public var changedFiles = 0
    public var untrackedFiles = 0
    /// Lines added and removed against HEAD, staged and unstaged together.
    public var insertions = 0
    public var deletions = 0

    public init() {}

    public var isClean: Bool { changedFiles == 0 && untrackedFiles == 0 }

    /// Reads `git status --porcelain=v2 --branch`. The diff counts come separately.
    public static func parse(porcelainV2 output: String) -> GitStatus {
        var s = GitStatus()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") {
                let oid = line.dropFirst("# branch.oid ".count)
                if oid != "(initial)" { s.commit = String(oid.prefix(7)) }
            } else if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                s.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                s.hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { s.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { s.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                s.changedFiles += 1
            } else if line.hasPrefix("? ") {
                s.untrackedFiles += 1
            }
        }
        return s
    }

    /// Reads `git diff --shortstat`: " 3 files changed, 12 insertions(+), 4 deletions(-)".
    /// Either count is left out when it is zero; an empty output means no changes.
    public static func parse(shortstat output: String) -> (insertions: Int, deletions: Int) {
        var ins = 0, del = 0
        for part in output.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let n = words.first.flatMap({ Int($0) }), words.count > 1 else { continue }
            if words[1].hasPrefix("insertion") { ins = n }
            if words[1].hasPrefix("deletion") { del = n }
        }
        return (ins, del)
    }
}
