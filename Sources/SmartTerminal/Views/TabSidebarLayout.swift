import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartTerminalCore

/// How a window lays out its tabs: the Chrome-style strip on top, or Mail-style
/// columns (groups, then sessions, then the terminal).
enum TabLayout: String {
    case strip, sidebar
    static let defaultsKey = "tabLayout"

    static var current: TabLayout {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TabLayout.init) ?? .strip
    }
}

/// What the left column has selected; the middle column lists its tabs.
enum TabCategory: Hashable {
    case all, ungrouped, group(UUID)

    func contains(_ tab: TerminalTab) -> Bool {
        switch self {
        case .all: true
        case .ungrouped: tab.groupID == nil
        case .group(let g): tab.groupID == g
        }
    }
}

/// The three-column layout: groups | sessions | terminal (and the trailing panel).
struct TabSidebarLayout<Detail: View>: View {
    let windowID: UUID
    let model: AppModel
    @ViewBuilder let detail: () -> Detail
    @State private var category: TabCategory = .all

    var body: some View {
        let window = model.window(windowID)
        NavigationSplitView {
            CategoryList(windowID: windowID, model: model, selection: $category)
                .navigationSplitViewColumnWidth(min: 140, ideal: 170, max: 260)
        } content: {
            SessionList(windowID: windowID, model: model, category: resolved(category, in: window))
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 400)
        } detail: {
            // The terminal wins over the lists when the window is narrow.
            VStack(spacing: 0) {
                DetailHeader(windowID: windowID, tab: window?.activeTab, model: model)
                detail()
            }
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 360)
        }
        .navigationSplitViewStyle(.balanced)
        // Translucent profiles clear the window background; without this the session
        // column and the margin around the floating sidebar showed the desktop.
        .background(Color(nsColor: .windowBackgroundColor))
        // A tab chosen elsewhere (⌘], a notification, a drop) brings its category along.
        .onChange(of: window?.activeTabID) { _, _ in
            guard let tab = model.window(windowID)?.activeTab,
                  !resolved(category, in: model.window(windowID)).contains(tab) else { return }
            category = tab.groupID.map { .group($0) } ?? .ungrouped
        }
        // Git state for the rows, only while this layout is on screen.
        .task(id: windowID) {
            while !Task.isCancelled {
                let tabs = model.window(windowID)?.tabs ?? []
                model.git.refresh(Set(tabs.compactMap { SessionRow.folder(of: $0, model: model) }))
                try? await Task.sleep(for: .seconds(4))
            }
        }
        // Picking a category shows one of its sessions, so the terminal matches the list.
        .onChange(of: category) { _, new in
            guard let w = model.window(windowID), let active = w.activeTab, !new.contains(active),
                  let first = w.tabs.first(where: new.contains) else { return }
            model.select(first.id)
        }
    }

    /// A group that no longer exists falls back to everything.
    private func resolved(_ c: TabCategory, in window: WindowLayout?) -> TabCategory {
        if case .group(let g) = c, window?.group(g) == nil { return .all }
        return c
    }
}

enum TabSidebarMetrics {
    /// The columns' top band, level with the traffic lights (Mail's toolbar height).
    static let headerHeight: CGFloat = 60
}

/// Mail's grouped toolbar buttons: icons sharing one glass capsule.
private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 2, content: content)
            .padding(.horizontal, 4)
            .frame(height: 34)
            .glassEffect(.regular, in: .capsule)
    }
}

/// One icon in a header's glass capsule.
private struct HeaderButton: View {
    let symbol: String
    let help: String
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(highlighted ? Color.accentColor : .primary)
                .frame(width: 32, height: 28)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Groups column

private struct CategoryList: View {
    let windowID: UUID
    let model: AppModel
    @Binding var selection: TabCategory

    var body: some View {
        let window = model.window(windowID)
        let tabs = window?.tabs ?? []
        let ungrouped = tabs.filter { $0.groupID == nil }
        // Plain rows, not a selection List: the group rows' double-click and drag
        // handlers swallowed List's single click, so groups couldn't be picked.
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                CategoryRow(title: "All Sessions", icon: .symbol("rectangle.stack"), tabs: tabs, model: model,
                            selected: selection == .all) { selection = .all }
                Text("Groups")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 2)
                ForEach(window?.orderedGroups ?? []) { group in
                    GroupCategoryRow(windowID: windowID, group: group,
                                     tabs: window?.tabs(in: group.id) ?? [], model: model,
                                     selected: selection == .group(group.id)) { selection = .group(group.id) }
                }
                if !ungrouped.isEmpty {
                    CategoryRow(title: "Ungrouped", icon: .symbol("terminal"), tabs: ungrouped, model: model,
                                selected: selection == .ungrouped) { selection = .ungrouped }
                        .onDrop(of: [.smartTerminalTab, .smartTerminalGroup],
                                delegate: StripDropDelegate(windowID: windowID, model: model) { _ in .end })
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            // Below the title bar's 28 pt: start level with the first session row.
            .padding(.top, TabSidebarMetrics.headerHeight - 28)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { newGroup() } label: { Label("New Group", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .help("New tab in a new group")
                Spacer()
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func newGroup() {
        model.newTab(in: windowID, nextToActive: false)
        guard let tab = model.window(windowID)?.activeTabID else { return }
        model.createGroup(with: tab)
        if let g = model.window(windowID)?.tab(tab)?.groupID {
            selection = .group(g)
            model.editingGroupID = g
        }
    }
}

private enum CategoryIcon {
    case symbol(String), color(Color)
}

private struct CategoryRow: View {
    let title: String
    let icon: CategoryIcon
    let tabs: [TerminalTab]
    let model: AppModel
    let selected: Bool
    var dimmed = false
    let select: () -> Void
    var doubleClick: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            switch icon {
            case .symbol(let s): Image(systemName: s).foregroundStyle(.secondary).frame(width: 16)
            case .color(let c): Circle().fill(c).frame(width: 10, height: 10).frame(width: 16)
            }
            Text(title).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(dimmed ? .secondary : .primary)
            Spacer(minLength: 4)
            if tabs.contains(where: { model.attention.contains($0.id) }) {
                Circle().fill(ClaudeGlyph.claudeOrange).frame(width: 7, height: 7)
                    .help("A session here needs you")
            }
            Text("\(tabs.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .onChange(of: model.currentDrag) { _, _ in hovering = false }
        // Same gesture pair as the strip's tabs: select on the first click, edit on a double.
        .onTapGesture(count: 2) { doubleClick?() }
        .simultaneousGesture(TapGesture().onEnded(select))
    }
}

/// A group in the source list: double-click (or the context menu) edits it,
/// tabs dropped on it join it, and it can be dragged to reorder groups.
private struct GroupCategoryRow: View {
    let windowID: UUID
    let group: TabGroup
    let tabs: [TerminalTab]
    let model: AppModel
    let selected: Bool
    let select: () -> Void

    private var hinted: Bool {
        model.activeDropHint == DropHint(windowID: windowID, target: .intoGroup(group.id))
    }

    var body: some View {
        CategoryRow(title: group.name.isEmpty ? "Unnamed \(group.color.displayName) Group" : group.name,
                    icon: .color(group.color.color), tabs: tabs, model: model,
                    selected: selected, dimmed: group.name.isEmpty, select: select,
                    doubleClick: { model.editingGroupID = group.id })
            .overlay {
                if hinted {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(group.color.color, lineWidth: 2)
                }
            }
            .popover(isPresented: Binding(
                get: { model.editingGroupID == group.id },
                set: { if !$0, model.editingGroupID == group.id { model.editingGroupID = nil } }
            ), arrowEdge: .trailing) {
                GroupEditor(group: group, windowID: windowID, model: model)
            }
            .contextMenu { GroupContextMenu(group: group, windowID: windowID, model: model) }
            .onDrag {
                model.beginDrag(.group(group.id))
                return NSItemProvider(item: group.id.uuidString as NSString,
                                      typeIdentifier: UTType.smartTerminalGroup.identifier)
            }
            .onDrop(of: [.smartTerminalTab, .smartTerminalGroup],
                    delegate: StripDropDelegate(windowID: windowID, model: model) { point in
                        switch model.currentDrag {
                        case .tab: .intoGroup(group.id)
                        case .group(let dragged): dragged == group.id ? nil
                            : point.y < 15 ? .beforeGroup(group.id) : .afterGroup(group.id)
                        case nil: nil
                        }
                    })
    }
}

/// The band above the terminal, level with the session header: what this terminal
/// is on the left, the trailing panel's toggle at the far right (above that panel).
private struct DetailHeader: View {
    let windowID: UUID
    let tab: TerminalTab?
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let tab {
                    Text(tab.displayTitle).font(.title3.weight(.bold)).lineLimit(1).truncationMode(.middle)
                    if let cwd = tab.cwd.map({ $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }),
                       cwd != tab.displayTitle {
                        Text(cwd)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
            }
            Spacer(minLength: 8)
            let open = model.isSidebarOpen(windowID)
            GlassGroup {
                HeaderButton(symbol: "sidebar.right", help: open ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)",
                             highlighted: open) { model.toggleSidebar(windowID) }
            }
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .padding(.top, 10)
        .frame(maxWidth: .infinity)
        .frame(height: TabSidebarMetrics.headerHeight, alignment: .top)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A row's git line: folder, branch chip, ahead/behind, then the uncommitted diff
/// as +12 −4 on the right (or a check when clean).
private struct GitLine: View {
    let status: GitStatus
    let folder: String?
    /// On the selected row's accent fill, where green and red don't read.
    let onAccent: Bool

    private var secondary: AnyShapeStyle {
        onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let folder {
                Text(folder).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
            }
            branchChip
            if status.ahead > 0 || status.behind > 0 {
                HStack(spacing: 3) {
                    if status.ahead > 0 { Text("↑\(status.ahead)") }
                    if status.behind > 0 { Text("↓\(status.behind)") }
                }
                .monospacedDigit()
                .help("\(status.ahead) ahead, \(status.behind) behind upstream")
            }
            Spacer(minLength: 4)
            diff
        }
        .font(.callout)
        .foregroundStyle(secondary)
        .lineLimit(1)
    }

    private var branchChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
            Text(status.branch ?? status.commit ?? "no commits")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(onAccent ? Color.white.opacity(0.2) : Color.primary.opacity(0.08)))
        .help(status.branch.map { "Branch \($0)" } ?? "Detached HEAD")
    }

    @ViewBuilder private var diff: some View {
        if status.isClean {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .help("No uncommitted changes")
        } else {
            HStack(spacing: 4) {
                if status.insertions > 0 || status.deletions > 0 {
                    Text("+\(status.insertions)")
                        .foregroundStyle(onAccent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.green))
                    Text("−\(status.deletions)")
                        .foregroundStyle(onAccent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.red))
                }
                if status.untrackedFiles > 0 {
                    Text("?\(status.untrackedFiles)")
                        .help(status.untrackedFiles == 1 ? "1 untracked file" : "\(status.untrackedFiles) untracked files")
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .help("\(status.changedFiles) changed, \(status.untrackedFiles) untracked · +\(status.insertions) −\(status.deletions) lines")
        }
    }
}

// MARK: - Sessions column

private struct SessionList: View {
    let windowID: UUID
    let model: AppModel
    let category: TabCategory

    var body: some View {
        let window = model.window(windowID)
        let tabs = (window?.tabs ?? []).filter(category.contains)
        // A plain stack, not a List: List's own click handling fought the rows'
        // drag and hover handlers, so a click only selected when it landed just right.
        VStack(spacing: 0) {
            header(window, count: tabs.count)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                        let active = window?.activeTabID == tab.id
                        SessionRow(windowID: windowID, tab: tab,
                                   group: category == .all ? tab.groupID.flatMap { window?.group($0) } : nil,
                                   isActive: active, model: model)
                        // Mail's hairlines between rows, left out next to the selection.
                        if i + 1 < tabs.count, !active, window?.activeTabID != tabs[i + 1].id {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10).padding(.bottom, 8)
            }
        }
        // Up under the transparent title bar, so the header sits level with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Mail's list header: big title, a count below it, and grouped glass buttons.
    private func header(_ window: WindowLayout?, count: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title(window)).font(.title3.weight(.bold)).lineLimit(1)
                Text(count == 1 ? "1 session" : "\(count) sessions")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            GlassGroup {
                HeaderButton(symbol: "plus", help: "New Tab Here (⌘T)", action: newTab)
            }
        }
        .padding(.leading, 20).padding(.trailing, 10)
        .padding(.top, 10)
        .frame(height: TabSidebarMetrics.headerHeight, alignment: .top)
    }

    private func title(_ window: WindowLayout?) -> String {
        switch category {
        case .all: "All Sessions"
        case .ungrouped: "Ungrouped"
        case .group(let g):
            window?.group(g).map { $0.name.isEmpty ? "Unnamed \($0.color.displayName) Group" : $0.name } ?? ""
        }
    }

    private func newTab() {
        switch category {
        case .group(let g): model.newTab(inGroup: g)
        case .all, .ungrouped: model.newTab(in: windowID, nextToActive: false)
        }
    }
}

/// A Mail-style row: title, then folder and running command, then Claude's last prompt as the preview.
private struct SessionRow: View {
    let windowID: UUID
    let tab: TerminalTab
    /// Shown as a color bar in "All Sessions", where rows from different groups mix.
    let group: TabGroup?
    let isActive: Bool
    let model: AppModel

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { model.renamingTabID == tab.id }
    private var agent: AgentSnapshot? { model.agents[tab.id] }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let group {
                Capsule().fill(group.color.color).frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    indicator
                    titleView
                    Spacer(minLength: 4)
                    closeButton.opacity(hovering || isActive ? 1 : 0)
                }
                // Always a second line, so every row is at least as tall (and as easy to hit).
                if let git = model.git.status(for: Self.folder(of: tab, model: model)) {
                    GitLine(status: git, folder: folderLabel, onAccent: isActive)
                } else {
                    Text(detail ?? " ")
                        .font(.callout)
                        .foregroundStyle(isActive ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.middle)
                }
                if let prompt = agent?.lastPrompt {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(isActive ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
        }
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onChange(of: model.currentDrag) { _, _ in hovering = false }
        // Same gesture pair as the strip's tabs: select on the first click, rename on a double.
        .onTapGesture(count: 2) { model.renamingTabID = tab.id }
        .simultaneousGesture(TapGesture().onEnded { model.select(tab.id) })
        .contextMenu { TabContextMenu(tab: tab, windowID: windowID, model: model) }
        .overlay(alignment: .top) { if hint == .beforeTab(tab.id) { dropLine.offset(y: -2) } }
        .overlay(alignment: .bottom) { if hint == .afterTab(tab.id) { dropLine.offset(y: 2) } }
        .onDrag {
            model.beginDrag(.tab(tab.id))
            return NSItemProvider(item: tab.id.uuidString as NSString,
                                  typeIdentifier: UTType.smartTerminalTab.identifier)
        } preview: {
            Text(tab.displayTitle).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        }
        .onDrop(of: [.smartTerminalTab, .smartTerminalGroup],
                delegate: StripDropDelegate(windowID: windowID, model: model) { point in
                    point.y < 24 ? .beforeTab(tab.id) : .afterTab(tab.id)
                })
    }

    private var hint: DropTarget? {
        model.activeDropHint?.windowID == windowID ? model.activeDropHint?.target : nil
    }

    private var dropLine: some View {
        Capsule().fill(group?.color.color ?? .accentColor).frame(height: 3)
    }

    @ViewBuilder private var titleView: some View {
        if isRenaming {
            TextField("Tab name", text: $draft)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(commitRename)
                .onExitCommand { model.renamingTabID = nil }
                .onChange(of: fieldFocused) { _, focused in if !focused { commitRename() } }
                .onAppear {
                    draft = tab.customTitle ?? tab.displayTitle
                    DispatchQueue.main.async { fieldFocused = true }
                }
        } else {
            Text(tab.displayTitle)
                .font(.body.weight(.semibold))
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// Folder, and what runs in it when that isn't already the title.
    /// The folder git runs in: the shell's live one, else the last one saved.
    static func folder(of tab: TerminalTab, model: AppModel) -> String? {
        model.sessions.currentDirectory(of: tab.id) ?? tab.cwd
    }

    /// The folder's name, when the title doesn't already say it.
    private var folderLabel: String? {
        guard let cwd = Self.folder(of: tab, model: model) else { return nil }
        let folder = TerminalSession.prettyFolder(cwd)
        return folder == tab.displayTitle ? nil : folder
    }

    private var detail: String? {
        var parts: [String] = []
        if let cwd = agent?.cwd ?? tab.cwd {
            let folder = TerminalSession.prettyFolder(cwd)
            if folder != tab.displayTitle { parts.append(folder) }
        }
        if let cmd = model.titleBars[tab.id]?.command, !tab.displayTitle.contains(cmd) { parts.append(cmd) }
        if let n = agent?.prNumber { parts.append("PR #\(n)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var indicator: some View {
        if let agent {
            ClaudeGlyph(status: agent.status, waiting: model.attention.contains(tab.id))
        } else if model.attention.contains(tab.id) {
            Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(.orange)
        } else if model.activity.contains(tab.id) {
            Circle().fill(group?.color.color ?? .accentColor).frame(width: 6, height: 6)
        }
    }

    private var closeButton: some View {
        Button { model.requestCloseTab(tab.id) } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        .help("Close Tab (⌘W)")
    }

    private func commitRename() {
        guard isRenaming else { return }
        model.rename(tab: tab.id, to: draft == tab.autoTitle ? nil : draft)
        model.renamingTabID = nil
    }
}
