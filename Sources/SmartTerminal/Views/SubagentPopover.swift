import SwiftUI
import SmartTerminalCore

/// Follows one subagent's transcript while its popover is open. The file is found
/// through the `.meta.json` Claude writes next to it, which names the Agent tool
/// call that started it, so a subagent can be found while it's still running.
@MainActor
@Observable
final class SubagentFeed {
    private(set) var activity = SubagentActivity()
    private(set) var found = false

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let toolUseID: String
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var offset: UInt64 = 0
    @ObservationIgnored private var partial = Data()

    /// `transcriptPath` is the session's; its subagents live in `<session>/subagents/`.
    init(transcriptPath: String, toolUseID: String) {
        directory = URL(fileURLWithPath: transcriptPath).deletingPathExtension().appendingPathComponent("subagents")
        self.toolUseID = toolUseID
    }

    /// Reads what's new since the last call. Cheap: only appended bytes are read.
    func poll() {
        if url == nil { url = locate() }
        guard let url, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        found = true
        let size = (try? h.seekToEnd()) ?? 0
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        let data = (try? h.read(upToCount: Int(min(size - offset, 8 * 1024 * 1024)))) ?? Data()
        offset += UInt64(data.count)
        var buffer = partial + data
        guard let last = buffer.lastIndex(of: UInt8(ascii: "\n")) else { partial = buffer; return }
        partial = buffer[(last + 1)...]
        buffer = buffer[..<last]
        for line in buffer.split(separator: UInt8(ascii: "\n")) {
            if let s = String(data: line, encoding: .utf8) { activity.ingest(line: s) }
        }
    }

    private func locate() -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names where name.hasSuffix(".meta.json") {
            let meta = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: meta),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["toolUseId"] as? String == toolUseID else { continue }
            let transcript = directory.appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
            return fm.fileExists(atPath: transcript.path) ? transcript : nil
        }
        return nil
    }
}

/// 600×400 popover: what the subagent is doing now, then its activity as a mini
/// terminal in Claude Code's own style, following the newest line.
struct SubagentPopover: View {
    let agent: ClaudeSubagent
    let stale: Bool
    @State private var feed: SubagentFeed

    init(agent: ClaudeSubagent, stale: Bool, transcriptPath: String) {
        self.agent = agent
        self.stale = stale
        _feed = State(initialValue: SubagentFeed(transcriptPath: transcriptPath, toolUseID: agent.id))
    }

    private static let bottom = "bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(feed.activity.entries.enumerated()), id: \.offset) { _, entry in
                            EntryView(entry: entry)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: feed.activity.entries.count) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .background(Color(nsColor: NSColor(white: 0.08, alpha: 1)))
            .overlay {
                if !feed.found {
                    Text("This subagent's transcript isn't available.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 600, height: 400)
        .environment(\.colorScheme, .dark)
        // Reads new lines once a second, only while the popover is open.
        .task {
            while !Task.isCancelled {
                feed.poll()
                if agent.status != .running || stale, feed.found { break } // finished: nothing more will come
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent.description).font(.headline).lineLimit(1)
                Spacer()
                Text([agent.type, feed.activity.model].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            // The latest tool call, so the popover answers "what is it doing?" at a glance.
            if let now = latestTool {
                HStack(spacing: 6) {
                    Text(agent.status == .running && !stale ? "Now" : "Last")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(agent.status == .running && !stale ? ClaudeGlyph.claudeOrange : .secondary)
                    Text("\(now.name)(\(now.summary))")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var latestTool: (name: String, summary: String)? {
        for entry in feed.activity.entries.reversed() {
            if case .tool(_, let name, let summary, _, _) = entry { return (name, summary) }
        }
        return nil
    }
}

private struct EntryView: View {
    let entry: SubagentActivity.Entry
    private static let mono = Font.system(size: 11, design: .monospaced)

    var body: some View {
        switch entry {
        case .task(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("›").foregroundStyle(.secondary)
                Text(text).foregroundStyle(.secondary).lineLimit(6)
            }
            .font(Self.mono)
        case .text(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⏺").foregroundStyle(.white)
                Text(text).foregroundStyle(.white)
            }
            .font(Self.mono)
        case .tool(_, let name, let summary, let result, let isError):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("⏺").foregroundStyle(result == nil ? ClaudeGlyph.claudeOrange : isError ? .red : .green)
                    (Text(name).bold() + Text("(\(summary))")).foregroundStyle(.white)
                }
                if let result {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("  ⎿").foregroundStyle(.secondary)
                        Text(result).foregroundStyle(isError ? Color.red.opacity(0.9) : .secondary)
                    }
                }
            }
            .font(Self.mono)
        }
    }
}
