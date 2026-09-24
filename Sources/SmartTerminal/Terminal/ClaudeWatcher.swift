import Foundation
import SmartTerminalCore

/// Follows the Claude Code session whose process group is in the foreground of
/// a tab's pty. Polled by TerminalSession (≈1s); all reads are small:
/// the session JSON is tiny, and the transcript is tailed from a byte offset.
@MainActor
final class ClaudeWatcher {
    private static var claudeDir: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    private(set) var pid: pid_t = 0
    /// argv of the Claude process, captured once per pid (for resuming with the same flags).
    private(set) var arguments: [String] = []
    private var record: ClaudeSessionRecord?
    private var transcriptURL: URL?
    private var transcriptOffset: UInt64 = 0
    private var partialLine = Data()
    private var transcript = ClaudeTranscriptState()
    private var lastLookup = Date.distantPast

    /// Returns the snapshot for the foreground process group, or nil when it is not Claude.
    func update(foregroundPGID: pid_t?, terminalTitle: String?) -> AgentSnapshot? {
        let osc = terminalTitle.flatMap(ClaudeTitle.parse)
        guard let pgid = foregroundPGID else { reset(); return nil }
        if pgid != pid { reset(); pid = pgid; arguments = ProcessInspector.arguments(of: pgid) ?? [] }

        record = readRecord(pid: pgid)
        guard record != nil || osc != nil else { return nil }

        if let rec = record {
            if transcriptURL == nil || !(transcriptURL!.lastPathComponent.hasPrefix(rec.sessionId)) {
                // Session changed (/clear, /resume) or transcript not created yet (before the first prompt).
                if Date().timeIntervalSince(lastLookup) > 3 || transcriptURL != nil {
                    lastLookup = Date()
                    attachTranscript(sessionID: rec.sessionId, cwd: rec.cwd)
                }
            } else {
                tailTranscript()
            }
        }
        return AgentSnapshot.make(record: record, transcript: transcriptURL == nil ? nil : transcript,
                                  terminalTitle: osc)
    }

    private func reset() {
        pid = 0; arguments = []; record = nil; transcriptURL = nil; transcriptOffset = 0
        partialLine = Data(); transcript = ClaudeTranscriptState()
    }

    private func readRecord(pid: pid_t) -> ClaudeSessionRecord? { Self.sessionRecord(pid: pid) }

    /// `~/.claude/sessions/<pid>.json`, if that pid is a live Claude Code session.
    static func sessionRecord(pid: pid_t) -> ClaudeSessionRecord? {
        let url = Self.claudeDir.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let rec = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data),
              rec.pid == pid else { return nil }
        return rec
    }

    // MARK: - Transcript

    private func attachTranscript(sessionID: String, cwd: String?) {
        transcriptURL = nil; transcriptOffset = 0; partialLine = Data(); transcript = ClaudeTranscriptState()
        let projects = Self.claudeDir.appendingPathComponent("projects", isDirectory: true)
        let file = "\(sessionID).jsonl"
        // Fast path: Claude's directory naming replaces every non-alphanumeric char with "-".
        var candidates: [URL] = []
        if let cwd {
            let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            candidates.append(projects.appendingPathComponent(encoded).appendingPathComponent(file))
        }
        let fm = FileManager.default
        var url = candidates.first { fm.fileExists(atPath: $0.path) }
        if url == nil, let dirs = try? fm.contentsOfDirectory(atPath: projects.path) {
            url = dirs.lazy.map { projects.appendingPathComponent($0).appendingPathComponent(file) }
                .first { fm.fileExists(atPath: $0.path) }
        }
        guard let url else { return }
        transcriptURL = url
        scanBackwardsForTitles(url)
    }

    /// Titles repeat through the file, but can be megabytes apart: read growing
    /// windows from the end until one turns up, then tail from EOF.
    private func scanBackwardsForTitles(_ url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var window: UInt64 = 512 * 1024
        while true {
            let start = size > window ? size - window : 0
            try? h.seek(toOffset: start)
            let data = (try? h.read(upToCount: Int(size - start))) ?? Data()
            var state = ClaudeTranscriptState()
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            if start > 0, !lines.isEmpty { lines.removeFirst() } // likely cut mid-line
            for line in lines {
                if let s = String(data: line, encoding: .utf8) { state.ingest(line: s) }
            }
            transcript = state
            if state.hasTitle || start == 0 { break }
            window *= 4
        }
        transcriptOffset = size
    }

    private func tailTranscript() {
        guard let url = transcriptURL, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        guard size > transcriptOffset else {
            if size < transcriptOffset { transcriptOffset = 0 } // truncated/rewritten
            return
        }
        try? h.seek(toOffset: transcriptOffset)
        let data = (try? h.read(upToCount: Int(min(size - transcriptOffset, 8 * 1024 * 1024)))) ?? Data()
        transcriptOffset += UInt64(data.count)
        var buffer = partialLine + data
        if let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) {
            partialLine = buffer[(lastNewline + 1)...]
            buffer = buffer[..<lastNewline]
        } else {
            partialLine = buffer
            return
        }
        for line in buffer.split(separator: UInt8(ascii: "\n")) {
            if let s = String(data: line, encoding: .utf8) { transcript.ingest(line: s) }
        }
        if partialLine.count > 16 * 1024 * 1024 { partialLine = Data() } // runaway line; not a title entry
    }
}
