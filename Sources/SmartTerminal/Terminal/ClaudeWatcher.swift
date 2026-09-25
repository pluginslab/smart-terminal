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
    /// Token totals. Nil until the one-time background scan of the transcript so far
    /// finishes; lines tailed meanwhile wait in `pendingUsageLines`.
    private var usage: ClaudeUsage?
    private var pendingUsageLines: [String] = []
    private var scanGeneration = 0
    /// `~/.claude.json`'s hint about the window, per model; read at most once a minute.
    private var lastUsedWindow: (model: String, window: Int?, read: Date)?
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
                                  terminalTitle: osc,
                                  // No transcript yet (before the first prompt): nothing to count, not "loading".
                                  usage: transcriptURL == nil ? ClaudeUsage() : usageWithHints(),
                                  arguments: arguments)
    }

    private func reset() {
        pid = 0; arguments = []; record = nil; transcriptURL = nil; transcriptOffset = 0
        partialLine = Data(); transcript = ClaudeTranscriptState()
        usage = nil; pendingUsageLines = []; scanGeneration += 1; lastUsedWindow = nil
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
        usage = nil; pendingUsageLines = []; scanGeneration += 1
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
        scanUsage(url, upTo: transcriptOffset)
    }

    /// Totals need the whole transcript (it can be tens of MB), so it's read once in
    /// the background; tailing picks up from `offset`.
    private func scanUsage(_ url: URL, upTo offset: UInt64) {
        let generation = scanGeneration
        Task {
            let scanned = await TranscriptScanner.shared.usage(of: url, upTo: offset)
            guard generation == scanGeneration else { return } // session changed meanwhile
            var u = scanned
            pendingUsageLines.forEach { u.ingest(line: $0) } // the message-id set drops repeats
            pendingUsageLines = []
            usage = u
        }
    }

    private func usageWithHints() -> ClaudeUsage? {
        guard var u = usage else { return nil }
        if u.declaredWindow == nil, let model = u.model, let folder = record?.cwd {
            if lastUsedWindow?.model != model || Date().timeIntervalSince(lastUsedWindow!.read) > 60 {
                let json = try? Data(contentsOf: Self.claudeJSON)
                lastUsedWindow = (model, json.flatMap { ClaudeUsage.lastUsedWindow(claudeJSON: $0, folder: folder, model: model) }, Date())
            }
            u.lastUsedWindow = lastUsedWindow?.window
        }
        return u
    }

    /// Claude Code's state file: `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`.
    private static var claudeJSON: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    private func ingest(_ line: String) {
        transcript.ingest(line: line)
        if usage != nil { usage!.ingest(line: line) } else { pendingUsageLines.append(line) }
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
            if let s = String(data: line, encoding: .utf8) { ingest(s) }
        }
        if partialLine.count > 16 * 1024 * 1024 { partialLine = Data() } // runaway line; not a title entry
    }
}

/// Reads transcripts for token totals one at a time, off the main thread, so a
/// launch with many Claude tabs doesn't parse them all at once.
actor TranscriptScanner {
    static let shared = TranscriptScanner()

    func usage(of url: URL, upTo offset: UInt64) -> ClaudeUsage {
        var usage = ClaudeUsage()
        guard let h = try? FileHandle(forReadingFrom: url) else { return usage }
        defer { try? h.close() }
        var remaining = offset
        var carry = Data()
        while remaining > 0 {
            // 4 MB chunks keep memory flat for large transcripts.
            guard let chunk = try? h.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            var buffer = carry + chunk
            if remaining > 0, let last = buffer.lastIndex(of: UInt8(ascii: "\n")) {
                carry = buffer[(last + 1)...]
                buffer = buffer[..<last]
            } else {
                carry = Data()
            }
            for line in buffer.split(separator: UInt8(ascii: "\n")) {
                if let s = String(data: line, encoding: .utf8) { usage.ingest(line: s) }
            }
        }
        return usage
    }
}
