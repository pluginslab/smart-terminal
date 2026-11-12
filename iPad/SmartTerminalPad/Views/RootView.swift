import SwiftUI
import SmartTerminalCore

/// The Mac's Mail-style columns: groups | sessions | terminal.
///
/// Landscape shows the columns side by side. Portrait gives the terminal the whole
/// screen, as Mail does with a message: the lists slide in over it (swipe from the
/// left edge, or the button in the terminal header) and go away when you pick a
/// session. Laid over, not beside, so tmux doesn't reflow each time they appear.
struct RootView: View {
    @Bindable var model: PadModel
    /// Landscape's own choice (groups shown or not), kept while in portrait.
    @State private var landscapeColumns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columns) {
            CategoryList(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
                .toolbar(.hidden, for: .navigationBar)
        } content: {
            SessionList(model: model, columns: $model.columns)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            DetailColumn(model: model)
                .toolbar(.hidden, for: .navigationBar)
        }
        .modifier(SplitStyle(overlay: model.portrait))
        .background(Theme.list.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.selection)
        .onGeometryChange(for: Bool.self) { $0.size.height > $0.size.width } action: { portrait in
            guard portrait != model.portrait else { return }
            if portrait { landscapeColumns = model.columns }
            model.portrait = portrait
            model.columns = portrait ? .detailOnly : landscapeColumns
        }
        .onChange(of: model.selected) { _, _ in
            // Picking a session in portrait puts the lists away, as Mail does.
            if model.portrait, model.columns != .detailOnly {
                withAnimation(.snappy) { model.columns = .detailOnly }
            }
        }
        .onChange(of: model.category) { _, new in
            // Picking a category shows one of its sessions, so the terminal matches the list.
            let list = model.sessions(in: new)
            if !list.contains(where: { $0.name == model.selected }) { model.selected = list.first?.name }
        }
    }
}

/// Side by side in landscape, laid over the terminal in portrait.
private struct SplitStyle: ViewModifier {
    let overlay: Bool
    func body(content: Content) -> some View {
        if overlay { content.navigationSplitViewStyle(.prominentDetail) }
        else { content.navigationSplitViewStyle(.balanced) }
    }
}

// MARK: - Groups column

private struct CategoryList: View {
    @Bindable var model: PadModel

    var body: some View {
        let all = model.sessions
        let ungrouped = model.sessions(in: .ungrouped)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                HostBadge(host: model.host)
                    .padding(.horizontal, 8).padding(.bottom, 10)
                CategoryRow(title: "All Sessions", icon: .symbol("rectangle.stack"), sessions: all,
                            selected: model.category == .all) { model.category = .all }
                Text("Groups")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 2)
                ForEach(model.groups) { g in
                    CategoryRow(title: model.groupTitle(g), icon: .color(g.color.color),
                                sessions: model.sessions(in: .group(g.id)),
                                selected: model.category == .group(g.id), dimmed: g.name.isEmpty) {
                        model.category = .group(g.id)
                    }
                    .contextMenu { GroupMenu(model: model, group: g) }
                    .dropDestination(for: String.self) { names, _ in
                        names.forEach { model.move($0, to: g.id) }
                        return true
                    }
                }
                if !ungrouped.isEmpty {
                    CategoryRow(title: "Ungrouped", icon: .symbol("terminal"), sessions: ungrouped,
                                selected: model.category == .ungrouped) { model.category = .ungrouped }
                        .dropDestination(for: String.self) { names, _ in
                            names.forEach { model.move($0, to: nil) }
                            return true
                        }
                }
            }
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { model.newGroup() } label: { Label("New Group", systemImage: "plus") }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Theme.side.ignoresSafeArea())
    }
}

/// Which host the sessions come from, and whether it's reachable.
private struct HostBadge: View {
    let host: Host

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            Text(host.displayName).font(.callout.weight(.semibold))
            Spacer()
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }

    private var color: Color {
        switch host.state {
        case .connected: .green
        case .connecting: .yellow
        case .idle, .failed: .red
        }
    }
}

private struct GroupMenu: View {
    let model: PadModel
    let group: TabGroup
    @State private var naming = false

    var body: some View {
        Menu("Color") {
            ForEach(GroupColor.allCases, id: \.self) { c in
                Button(c.displayName) { model.updateGroup(group.id, color: c) }
            }
        }
        Button("Rename…") { model.renaming = "group:" + group.id.uuidString }
        Button("Ungroup", role: .destructive) { model.deleteGroup(group.id) }
    }
}

private enum CategoryIcon {
    case symbol(String), color(Color)
}

private struct CategoryRow: View {
    let title: String
    let icon: CategoryIcon
    let sessions: [RemoteSession]
    let selected: Bool
    var dimmed = false
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                switch icon {
                case .symbol(let s): Image(systemName: s).foregroundStyle(.secondary).frame(width: 18)
                case .color(let c): Circle().fill(c).frame(width: 11, height: 11).frame(width: 18)
                }
                Text(title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                Spacer(minLength: 4)
                if sessions.contains(where: { $0.agent == .waiting }) {
                    Circle().fill(Theme.claudeOrange).frame(width: 7, height: 7)
                }
                Text("\(sessions.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.selectionSoft : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

// MARK: - Sessions column

private struct SessionList: View {
    @Bindable var model: PadModel
    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        let list = model.sessions(in: model.category)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                // The groups column's toggle (the system one lives in the hidden nav bar).
                Button {
                    withAnimation(.snappy) { columns = groupsShown ? .doubleColumn : .all }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(groupsShown ? Theme.selection : Color.primary)
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .keyboardShortcut("s", modifiers: [.control, .command])
                .accessibilityLabel(groupsShown ? "Hide Groups" : "Show Groups")
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title3.weight(.bold)).lineLimit(1)
                    Text(list.count == 1 ? "1 session" : "\(list.count) sessions")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.newSession() } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .keyboardShortcut("t", modifiers: .command)
            }
            .padding(.leading, 20).padding(.trailing, 12)
            .frame(height: 64)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                        let active = model.selected == s.name
                        SessionRow(model: model, session: s, showGroup: model.category == .all, isActive: active)
                        if i + 1 < list.count, !active, model.selected != list[i + 1].name {
                            Divider().overlay(Theme.line).padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
            }
            .refreshable { await model.host.refresh() }
        }
        .background(Theme.list.ignoresSafeArea())
    }

    /// `.automatic` is what the system picks: groups shown in landscape, hidden in portrait.
    private var groupsShown: Bool { columns == .all }

    private var title: String {
        switch model.category {
        case .all: "All Sessions"
        case .ungrouped: "Ungrouped"
        case .group(let id): model.groups.first { $0.id == id }.map(model.groupTitle) ?? ""
        }
    }
}

/// A Mail-style row: title, then folder with git state, then what runs there.
private struct SessionRow: View {
    let model: PadModel
    let session: RemoteSession
    let showGroup: Bool
    let isActive: Bool

    private var onAccent: Color { Theme.onSelection }

    var body: some View {
        let group = model.group(of: session)
        HStack(alignment: .top, spacing: 8) {
            if showGroup, let group {
                Capsule().fill(group.color.color).frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let agent = session.agent { ClaudeGlyph(status: agent) }
                    Text(model.title(of: session))
                        .font(.body.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(session.lastActivity, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption)
                        .foregroundStyle(isActive ? AnyShapeStyle(onAccent.opacity(0.75)) : AnyShapeStyle(.secondary))
                }
                if let git = model.host.git[session.path] {
                    GitLine(status: git, folder: folder, onAccent: isActive)
                } else {
                    Text(folder ?? " ")
                        .font(.callout)
                        .foregroundStyle(isActive ? AnyShapeStyle(onAccent.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(isActive ? AnyShapeStyle(onAccent.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Theme.selection : .clear)
        }
        .foregroundStyle(isActive ? onAccent : Color.primary)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .hoverEffect(.highlight)
        .onTapGesture { model.selected = session.name }
        .draggable(session.name)
        .contextMenu {
            Button("Rename…") { model.renaming = session.name }
            Menu("Move to Group") {
                Button("New Group") { model.newGroup(with: session.name) }
                ForEach(model.groups) { g in
                    Button(model.groupTitle(g)) { model.move(session.name, to: g.id) }
                }
                if group != nil { Button("Remove from Group") { model.move(session.name, to: nil) } }
            }
            Divider()
            Button("Close Session", role: .destructive) { model.close(session.name) }
        }
    }

    private var folder: String? {
        let p = session.path
        guard !p.isEmpty else { return nil }
        let name = (p as NSString).lastPathComponent
        return name == model.title(of: session) ? nil : name
    }

    private var detail: String {
        var parts = ["tmux \(session.name)"]
        if session.agent == nil, !["zsh", "bash", "sh", "fish"].contains(session.command) { parts.append(session.command) }
        if session.attachedClients > (model.selected == session.name ? 1 : 0) { parts.append("also open elsewhere") }
        return parts.joined(separator: " · ")
    }
}

struct ClaudeGlyph: View {
    let status: AgentStatus

    var body: some View {
        switch status {
        case .busy:
            TimelineView(.animation(minimumInterval: 1 / 12)) { ctx in
                Image(systemName: "asterisk")
                    .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate * 180))
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.claudeOrange)
        case .waiting:
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.claudeOrange)
        case .idle:
            Image(systemName: "asterisk")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}

/// Folder, branch chip, ahead/behind, then the uncommitted diff (or a check when clean).
private struct GitLine: View {
    let status: GitStatus
    let folder: String?
    let onAccent: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let folder { Text(folder).lineLimit(1).truncationMode(.middle).layoutPriority(-1) }
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                Text(status.branch ?? status.commit ?? "no commits")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(onAccent ? Theme.onSelection.opacity(0.2) : Color.primary.opacity(0.08)))
            if status.ahead > 0 { Text("↑\(status.ahead)").monospacedDigit() }
            if status.behind > 0 { Text("↓\(status.behind)").monospacedDigit() }
            Spacer(minLength: 4)
            if status.isClean {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
            } else {
                HStack(spacing: 4) {
                    if status.insertions > 0 || status.deletions > 0 {
                        Text("+\(status.insertions)").foregroundStyle(onAccent ? Theme.onSelection : .green)
                        Text("−\(status.deletions)").foregroundStyle(onAccent ? Theme.onSelection : .red)
                    }
                    if status.untrackedFiles > 0 { Text("?\(status.untrackedFiles)") }
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
        .font(.callout)
        .foregroundStyle(onAccent ? AnyShapeStyle(Theme.onSelection.opacity(0.85)) : AnyShapeStyle(.secondary))
        .lineLimit(1)
    }
}
