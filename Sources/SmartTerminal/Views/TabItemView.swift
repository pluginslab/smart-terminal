import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartTerminalCore

struct TabItemView: View {
    let windowID: UUID
    let tab: TerminalTab
    let group: TabGroup?
    let isActive: Bool
    let width: CGFloat
    let model: AppModel

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { model.renamingTabID == tab.id }
    private var tint: Color { group?.color.color ?? .accentColor }

    var body: some View {
        HStack(spacing: 6) {
            indicator
            if isRenaming {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { model.renamingTabID = nil }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commitRename() } }
                    .onAppear {
                        draft = tab.customTitle ?? tab.displayTitle
                        DispatchQueue.main.async { fieldFocused = true }
                    }
            } else {
                (claudePrefix + Text(tab.displayTitle))
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            closeButton
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: StripMetrics.height - 8)
        .background(background)
        .overlay(alignment: .bottom) {
            if let group {
                // Group membership stripe, like Chrome's underline.
                Rectangle().fill(group.color.color).frame(height: 2).padding(.horizontal, 2)
            }
        }
        .overlay(alignment: .leading) { if hint == .beforeTab(tab.id) { DropBar(color: tint).offset(x: -2) } }
        .overlay(alignment: .trailing) { if hint == .afterTab(tab.id) { DropBar(color: tint).offset(x: 2) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A drag moves views out from under the pointer without a hover-exit.
        .onChange(of: model.currentDrag) { _, _ in hovering = false }
        .onTapGesture(count: 2) { model.renamingTabID = tab.id }
        .simultaneousGesture(TapGesture().onEnded { model.select(tab.id) })
        .onDrag {
            model.beginDrag(.tab(tab.id))
            return NSItemProvider(item: tab.id.uuidString as NSString,
                                  typeIdentifier: UTType.smartTerminalTab.identifier)
        } preview: {
            TabDragPreview(title: tab.displayTitle, color: group?.color.color)
        }
        .onDrop(of: [.smartTerminalTab, .smartTerminalGroup],
                delegate: StripDropDelegate(windowID: windowID, model: model) { point in
                    point.x < width / 2 ? .beforeTab(tab.id) : .afterTab(tab.id)
                })
        .contextMenu { TabContextMenu(tab: tab, windowID: windowID, model: model) }
        .help(tooltip)
    }

    private var tooltip: String {
        var lines = [tab.displayTitle]
        if let agent = model.agents[tab.id] {
            switch agent.status {
            case .busy: lines.append("Claude Code · working")
            case .waiting: lines.append("Claude Code · needs your answer" + (agent.waitingFor.map { " (\($0))" } ?? ""))
            case .idle: lines.append("Claude Code · idle")
            }
            if let t = agent.title, t != tab.displayTitle { lines.append(t) }
            if let p = agent.lastPrompt { lines.append("Last prompt: " + String(p.prefix(140))) }
            if let n = agent.prNumber { lines.append("PR #\(n)" + (agent.prURL.map { " · \($0)" } ?? "")) }
        }
        if let cwd = tab.cwd { lines.append(cwd) }
        return lines.joined(separator: "\n")
    }

    private var hint: DropTarget? {
        model.activeDropHint?.windowID == windowID ? model.activeDropHint?.target : nil
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if isActive {
            // Same color as the terminal below, so the active tab reads as "attached".
            shape.fill(Color(nsColor: model.sessions.profile.background.withAlphaComponent(1)))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
        } else if let group {
            shape.fill(group.color.color.opacity(hovering ? 0.22 : 0.12))
        } else {
            shape.fill(Color.primary.opacity(hovering ? 0.10 : 0.045))
        }
    }

    /// Claude's own animated status glyph (◐ ◑ while working, ✳ idle), taken live from
    /// the title it sets, so it stays in the tab even when you renamed it, like Terminal.app.
    private var claudePrefix: Text {
        guard model.agents[tab.id] != nil,
              let program = model.titleBars[tab.id]?.programTitle,
              let glyph = program.trimmingCharacters(in: .whitespaces).first,
              ClaudeTitle.parse(program) != nil else { return Text("") }
        return Text("\(String(glyph)) ").foregroundColor(ClaudeGlyph.claudeOrange)
    }

    @ViewBuilder private var indicator: some View {
        if let agent = model.agents[tab.id] {
            // The ◐/✳ prefix in the title shows working/idle; the icon only marks what needs you.
            if agent.status == .waiting || model.attention.contains(tab.id) {
                ClaudeGlyph(status: agent.status, waiting: model.attention.contains(tab.id))
            } else if model.titleBars[tab.id]?.programTitle.flatMap(ClaudeTitle.parse) == nil {
                ClaudeGlyph(status: agent.status, waiting: false) // no title glyph yet (before first prompt)
            }
        } else if model.attention.contains(tab.id) {
            Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(.orange)
        } else if model.activity.contains(tab.id) {
            Circle().fill(tint).frame(width: 6, height: 6)
        }
    }

    private var closeButton: some View {
        Button { model.requestCloseTab(tab.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(hovering || isActive ? 1 : 0)
        .help("Close Tab (⌘W)")
    }

    private func commitRename() {
        guard isRenaming else { return }
        // Renaming to the automatic title (or blank) clears the custom name.
        let value = draft == tab.autoTitle ? nil : draft
        model.rename(tab: tab.id, to: value)
        model.renamingTabID = nil
    }
}

private struct TabDragPreview: View {
    let title: String
    let color: Color?
    var body: some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 8, height: 8) }
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct TabContextMenu: View {
    let tab: TerminalTab
    let windowID: UUID
    let model: AppModel

    var body: some View {
        let window = model.window(windowID)
        Button("Rename Tab…") { model.renamingTabID = tab.id }
        if tab.customTitle != nil {
            Button("Use Automatic Name") { model.rename(tab: tab.id, to: nil) }
        }
        Divider()
        Button("Add Tab to New Group") { model.createGroup(with: tab.id) }
        let otherGroups = (window?.orderedGroups ?? []).filter { $0.id != tab.groupID }
        if !otherGroups.isEmpty {
            Menu("Add Tab to Group") {
                ForEach(otherGroups) { g in
                    Button(g.name.isEmpty ? "Unnamed \(g.color.displayName) Group" : g.name) {
                        model.addTab(tab.id, toGroup: g.id)
                    }
                }
            }
        }
        if tab.groupID != nil {
            Button("Remove from Group") { model.removeFromGroup(tab.id) }
        }
        Divider()
        Button("Move Tab to New Window") { model.moveTabToNewWindow(tab.id) }
            .disabled((window?.tabs.count ?? 0) < 2)
        Divider()
        Button("Close Tab") { model.requestCloseTab(tab.id) }
        Button("Close Other Tabs") { model.closeOtherTabs(keeping: tab.id) }
            .disabled((window?.tabs.count ?? 0) < 2)
    }
}

/// Claude Code status in a tab: a spinning sparkle while working, a still one when
/// idle, and an orange one when it finished in the background and waits for you.
struct ClaudeGlyph: View {
    let status: AgentStatus
    let waiting: Bool
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        switch status {
        case .busy:
            TimelineView(.animation(minimumInterval: 1 / 12)) { ctx in
                Image(systemName: "asterisk")
                    .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate * 180))
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Self.claudeOrange)
            .help("Claude is working")
        case .waiting:
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.claudeOrange)
                .help("Claude needs your answer")
        case .idle:
            Image(systemName: waiting ? "asterisk.circle.fill" : "asterisk")
                .font(.system(size: waiting ? 11 : 10, weight: .bold))
                .foregroundStyle(waiting ? Self.claudeOrange : Color.secondary)
                .help(waiting ? "Claude finished and is waiting for you" : "Claude is idle")
        }
    }
}
