import Foundation
import Observation
import SmartTerminalCore

/// Git state per folder, for the session rows. Tabs in the same folder share one
/// lookup. Refreshed by whoever shows it (the columns layout polls while on screen).
@MainActor
@Observable
final class GitStatusStore {
    /// Folder → status. A folder outside any repository has no entry.
    private(set) var statuses: [String: GitStatus] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    func status(for path: String?) -> GitStatus? { path.flatMap { statuses[$0] } }

    func refresh(_ paths: Set<String>) {
        for path in paths where inFlight.insert(path).inserted {
            Task.detached(priority: .utility) {
                let status = Self.read(path)
                await MainActor.run {
                    self.inFlight.remove(path)
                    if self.statuses[path] != status { self.statuses[path] = status }
                }
            }
        }
    }

    /// Two git calls: status for branch and files, diff for line counts.
    private nonisolated static func read(_ path: String) -> GitStatus? {
        guard let out = git(["status", "--porcelain=v2", "--branch"], in: path) else { return nil }
        var status = GitStatus.parse(porcelainV2: out)
        if !status.isClean, status.commit != nil || status.branch != nil,
           let stat = git(["diff", "--shortstat", "HEAD"], in: path) {
            (status.insertions, status.deletions) = GitStatus.parse(shortstat: stat)
        }
        return status
    }

    /// Output on success, nil when git fails (not a repository, no commits yet, no git).
    private nonisolated static func git(_ args: [String], in path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        var env = ProcessInfo.processInfo.environment
        // A background status must not take index.lock while you commit in a tab.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile() // before waiting: a full pipe would block git
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
