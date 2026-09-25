import SwiftUI
import SmartTerminalCore

/// The sidebar's Claude pane: the Claude Code session in the window's active tab.
/// Follows tab switches; everything comes from the session file and transcript
/// the tab already watches.
struct ClaudePanel: View {
    let windowID: UUID
    let model: AppModel

    var body: some View {
        let tab = model.window(windowID)?.activeTab
        let agent = tab.flatMap { model.agents[$0.id] }
        VStack(spacing: 0) {
            HStack {
                Text("Claude Code").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Divider()
            if let tab, let agent {
                ScrollView {
                    ClaudeSessionCards(agent: agent, title: tab.displayTitle, needsYou: model.attention.contains(tab.id))
                        .padding(10)
                }
            } else {
                ContentUnavailableView {
                    Label("No Claude Session", systemImage: "asterisk")
                } description: {
                    Text("Run claude in this tab to see its status, context and tokens here.")
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Cards

/// Status, context, tokens and facts for one session.
struct ClaudeSessionCards: View {
    let agent: AgentSnapshot
    /// The tab's name, which falls back to "Claude · folder" like the tab does.
    let title: String
    let needsYou: Bool

    var body: some View {
        VStack(spacing: 10) {
            StatusCard(agent: agent, title: title, needsYou: needsYou)
            if let usage = agent.usage, usage.prompts == 0, usage.totalTokens == 0 {
                Text("No prompts yet. Context and tokens show up after Claude's first reply.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16).padding(.horizontal, 8)
            } else if let usage = agent.usage {
                if !usage.subagents.isEmpty {
                    SubagentsCard(usage: usage, transcriptPath: agent.transcriptPath)
                }
                ContextCard(usage: usage)
                TokensCard(usage: usage)
                FactsCard(usage: usage, startedAt: agent.startedAt, resumed: agent.resumed)
            } else {
                ProgressView("Reading transcript…")
                    .controlSize(.small)
                    .padding(.top, 20)
            }
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary))
    }
}

/// Big animated glyph, session title, and what it's doing: working with a turn
/// timer, waiting on you (and why), or idle since the last reply.
private struct StatusCard: View {
    let agent: AgentSnapshot
    let title: String
    let needsYou: Bool

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 12) {
                StatusGlyph(status: agent.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    statusLine
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch agent.status {
        case .busy:
            // Ticks every second only while working, and only while this pane is on screen.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if let start = agent.usage?.lastPromptAt {
                    Text("Working · ") + Text(Duration.seconds(max(0, ctx.date.timeIntervalSince(start)))
                        .formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                } else {
                    Text("Working")
                }
            }
            .foregroundStyle(ClaudeGlyph.claudeOrange)
        case .waiting:
            Text("Needs you" + (agent.waitingFor.map { " · \($0)" } ?? ""))
                .foregroundStyle(ClaudeGlyph.claudeOrange)
                .fontWeight(.semibold)
        case .idle:
            TimelineView(.periodic(from: .now, by: 10)) { ctx in
                if let last = agent.usage?.lastReplyAt {
                    Text((needsYou ? "Finished" : "Idle") + " · last reply " + ClipRow.age(of: last, now: ctx.date))
                } else {
                    Text("Idle")
                }
            }
            .foregroundStyle(needsYou ? AnyShapeStyle(ClaudeGlyph.claudeOrange) : AnyShapeStyle(.secondary))
        }
    }
}

/// The tab's glyph at hero size: spins while working, with a soft pulse behind it.
private struct StatusGlyph: View {
    let status: AgentStatus

    var body: some View {
        ZStack {
            Circle().fill(ClaudeGlyph.claudeOrange.opacity(status == .idle ? 0.10 : 0.16))
            switch status {
            case .busy:
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    ZStack {
                        Circle()
                            .stroke(ClaudeGlyph.claudeOrange.opacity(0.35 * (1 - (t.truncatingRemainder(dividingBy: 1.6) / 1.6))), lineWidth: 2)
                            .scaleEffect(1 + 0.35 * (t.truncatingRemainder(dividingBy: 1.6) / 1.6))
                        Image(systemName: "asterisk")
                            .font(.system(size: 18, weight: .bold))
                            .rotationEffect(.degrees(t * 120))
                    }
                }
                .foregroundStyle(ClaudeGlyph.claudeOrange)
            case .waiting:
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClaudeGlyph.claudeOrange)
                    .symbolEffect(.pulse)
            case .idle:
                Image(systemName: "asterisk")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(ClaudeGlyph.claudeOrange.opacity(0.8))
            }
        }
        .frame(width: 40, height: 40)
    }
}

/// Subagents Claude started, newest first: running ones with a live timer,
/// finished ones with duration, tokens and tool calls.
private struct SubagentsCard: View {
    let usage: ClaudeUsage
    let transcriptPath: String?

    static let visible = 8

    private var subagents: [ClaudeSubagent] { usage.subagents }
    private func isStale(_ a: ClaudeSubagent) -> Bool { usage.isStale(a) }

    var body: some View {
        let newestFirst = Array(subagents.reversed())
        let running = subagents.filter { $0.status == .running && !isStale($0) }.count
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Subagents").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if running > 0 {
                        Text("\(running) running")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ClaudeGlyph.claudeOrange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(ClaudeGlyph.claudeOrange.opacity(0.15)))
                    }
                }
                ForEach(newestFirst.prefix(Self.visible)) { a in
                    SubagentRow(agent: a, stale: isStale(a), transcriptPath: transcriptPath)
                }
                if newestFirst.count > Self.visible {
                    Text("and \(newestFirst.count - Self.visible) earlier")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SubagentRow: View {
    let agent: ClaudeSubagent
    let stale: Bool
    let transcriptPath: String?

    @State private var showActivity = false
    @State private var overRow = false
    @State private var overPopover = false
    @State private var hovering = false

    var body: some View {
        row
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                overRow = inside
                inside ? openSoon() : closeSoon()
            }
            .popover(isPresented: $showActivity, arrowEdge: .leading) {
                if let transcriptPath {
                    SubagentPopover(agent: agent, stale: stale, transcriptPath: transcriptPath)
                        .onHover { inside in overPopover = inside; if !inside { closeSoon() } }
                }
            }
    }

    /// Hover intent: open after a short pause, so sweeping past rows doesn't pop things up.
    private func openSoon() {
        guard transcriptPath != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if overRow { showActivity = true } }
    }

    /// Close once the pointer has left both the row and the popover (moving between
    /// them crosses a gap, hence the grace period).
    private func closeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !overRow && !overPopover { showActivity = false }
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.description)
                    .font(.system(size: 12, weight: agent.status == .running && !stale ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    // "general-purpose" is the default and says nothing; other types (Explore…) do.
                    let type = agent.type.flatMap { $0 == "general-purpose" ? nil : $0 }
                    if let type { Text(type); Text("·") }
                    if agent.background { Text("background"); Text("·") }
                    detail
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch (agent.status, stale) {
        case (.running, false):
            // Claude's own asterisk, spinning like the tab's, rather than a generic spinner.
            TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                Image(systemName: "asterisk")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate * 180))
            }
            .foregroundStyle(ClaudeGlyph.claudeOrange)
        case (.running, true):
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case (.completed, _):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case (.failed, _):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var detail: some View {
        switch agent.status {
        case .running where stale:
            Text("didn't finish")
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if let start = agent.startedAt {
                    Text(Duration.seconds(max(0, ctx.date.timeIntervalSince(start))).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                } else {
                    Text("running")
                }
            }
        case .completed, .failed:
            Text(stats)
        }
    }

    /// "1 min 30 s · 41k tokens · 12 tools", or "failed".
    private var stats: String {
        var parts: [String] = []
        if agent.status == .failed { parts.append("failed") }
        if let d = agent.duration { parts.append(Duration.seconds(d).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))) }
        if let t = agent.totalTokens { parts.append("\(TokenCount.short(t)) tokens") }
        if let n = agent.toolUses { parts.append(n == 1 ? "1 tool" : "\(n) tools") }
        return parts.isEmpty ? "done" : parts.joined(separator: " · ")
    }
}

/// How full the context is: a ring against the (inferred) window, and the count.
private struct ContextCard: View {
    let usage: ClaudeUsage

    private var window: (tokens: Int, source: ClaudeUsage.WindowSource) { usage.contextWindow }
    private var fraction: Double { min(1, Double(usage.contextTokens) / Double(window.tokens)) }

    /// Where the window size came from; replies don't record it.
    private var windowHelp: String {
        switch window.source {
        case .declared: "From this session's /context or /model output."
        case .observed: "This session has gone past 200k, so it has the 1M window."
        case .lastUsed: "From the model this folder's last Claude session used. Run /context in Claude to confirm."
        case .assumed: "Claude doesn't log the context window. 200k is assumed; run /context in Claude to set it."
        }
    }
    private var tint: Color { fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .accentColor }

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.snappy, value: fraction)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context").font(.caption).foregroundStyle(.secondary)
                    Text(TokenCount.short(usage.contextTokens))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    // An assumed window is marked, so a guess never reads as fact.
                    Text("of \(window.source == .assumed ? "~" : "")\(TokenCount.short(window.tokens)) tokens")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(windowHelp)
                }
            }
        }
    }
}

/// Session totals. Cache reads dominate: each turn re-reads the cached conversation.
private struct TokensCard: View {
    let usage: ClaudeUsage

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tokens this session").font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Output", usage.outputTokens, help: "Written by Claude, including thinking")
                    row("Input", usage.inputTokens, help: "New input that wasn't cached")
                    row("Cache read", usage.cacheReadTokens, help: "Conversation re-read from the prompt cache on each turn")
                    row("Cache write", usage.cacheCreationTokens, help: "Added to the prompt cache")
                    Divider().gridCellColumns(2)
                    GridRow {
                        Text("Total").fontWeight(.semibold)
                        Text(TokenCount.short(usage.totalTokens)).fontWeight(.semibold)
                            .monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private func row(_ label: String, _ value: Int, help: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(TokenCount.short(value)).monospacedDigit().gridColumnAlignment(.trailing)
                .contentTransition(.numericText())
        }
        .help(help)
    }
}

private struct FactsCard: View {
    let usage: ClaudeUsage
    let startedAt: Date?
    /// This process resumed an older transcript, so its start isn't the conversation's.
    let resumed: Bool

    var body: some View {
        Card {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                fact("Prompts", "\(usage.prompts)")
                if let d = usage.lastTurnDuration {
                    fact("Last turn", Duration.seconds(d).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                }
                if let startedAt {
                    // The timeline wraps only the value: a Grid only lays out direct GridRows.
                    GridRow {
                        Text(resumed ? "Resumed" : "Started").foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 10)) { ctx in
                            Text(ClipRow.age(of: startedAt, now: ctx.date))
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if let m = usage.model { fact("Model", m) }
            }
            .font(.system(size: 12))
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

enum TokenCount {
    /// 260 → "260", 4_200 → "4.2k", 276_633 → "277k", 23_875_323 → "23.9M".
    static func short(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1_000)
        case ..<1_000_000: return "\(Int((Double(n) / 1_000).rounded()))k"
        default:
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
    }
}
