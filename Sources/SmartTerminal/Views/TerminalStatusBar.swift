import SwiftUI
import SmartTerminalCore

/// The strip under the terminal. With Claude Code running: its status, subagents,
/// model, context and tokens, and a click opens the full session cards. Without:
/// folder, command and size. Always there, so Claude starting never resizes the grid.
struct TerminalStatusBar: View {
    let tab: TerminalTab?
    let model: AppModel

    var body: some View {
        Group {
            if let tab, let agent = model.agents[tab.id] {
                // One identity per tab: a tab switch shows the new values outright,
                // instead of animating the ring from the previous tab's.
                ClaudeStatusBar(agent: agent, needsYou: model.attention.contains(tab.id), title: tab.displayTitle)
                    .id(tab.id)
            } else {
                ShellStatusBar(cwd: tab?.cwd, info: tab.flatMap { model.titleBars[$0.id] })
            }
        }
        .frame(height: StatusBarMetrics.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

enum StatusBarMetrics {
    static let height: CGFloat = 28
}

private struct ShellStatusBar: View {
    let cwd: String?
    let info: TitleBarInfo?

    var body: some View {
        HStack(spacing: 6) {
            if let cwd {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let cmd = info?.command { Text(cmd) }
            if let info, info.cols > 0 {
                Text("\(info.cols)×\(info.rows)").monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }
}

/// Claude's status left, the numbers right. Clicking anywhere opens the session cards.
struct ClaudeStatusBar: View {
    let agent: AgentSnapshot
    let needsYou: Bool
    var title = "Claude Code"

    @State private var showDetails = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            status
            if let running = runningSubagents, running > 0 {
                Divider().frame(height: 12)
                Label(running == 1 ? "1 subagent" : "\(running) subagents", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(ClaudeGlyph.claudeOrange)
            }
            Spacer(minLength: 8)
            if let usage = agent.usage, usage.prompts > 0 || usage.totalTokens > 0 {
                if let m = usage.model {
                    Text(ModelName.pretty(m)).help(m)
                    Divider().frame(height: 12)
                }
                ContextGauge(usage: usage)
                Divider().frame(height: 12)
                Text("\(TokenCount.short(usage.totalTokens)) tokens")
                    .monospacedDigit()
                    .help("Output \(TokenCount.short(usage.outputTokens)) · input \(TokenCount.short(usage.inputTokens)) · cache read \(TokenCount.short(usage.cacheReadTokens)) · cache write \(TokenCount.short(usage.cacheCreationTokens))")
            }
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(hovering ? 0.05 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { showDetails.toggle() }
        .help("Show session details")
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            ScrollView {
                ClaudeSessionCards(agent: agent, title: title, needsYou: needsYou).padding(10)
            }
            .frame(width: 320)
            .frame(maxHeight: 560)
        }
    }

    private var runningSubagents: Int? {
        agent.usage.map { u in u.subagents.filter { $0.status == .running && !u.isStale($0) }.count }
    }

    /// The tab's glyph, then what Claude is doing: same wording as the session card.
    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            ClaudeGlyph(status: agent.status, waiting: needsYou)
            switch agent.status {
            case .busy:
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
                    .fontWeight(.semibold)
                    .foregroundStyle(ClaudeGlyph.claudeOrange)
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
        .lineLimit(1)
    }
}

/// A small context ring and "112k / 200k", tinted as the window fills.
private struct ContextGauge: View {
    let usage: ClaudeUsage

    var body: some View {
        let window = usage.contextWindow
        let fraction = min(1, Double(usage.contextTokens) / Double(window.tokens))
        let tint: Color = fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .accentColor
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: fraction)
            }
            .frame(width: 12, height: 12)
            // An assumed window is marked, so a guess never reads as fact.
            Text("\(TokenCount.short(usage.contextTokens)) / \(window.source == .assumed ? "~" : "")\(TokenCount.short(window.tokens))")
                .monospacedDigit()
        }
        .help("Context: \(Int((fraction * 100).rounded()))% used")
    }
}
