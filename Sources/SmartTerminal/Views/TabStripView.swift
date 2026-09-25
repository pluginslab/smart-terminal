import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartTerminalCore

extension UTType {
    static let smartTerminalTab = UTType(exportedAs: "com.pluginslab.smartterminal.tab")
    static let smartTerminalGroup = UTType(exportedAs: "com.pluginslab.smartterminal.group")
}

enum StripMetrics {
    static let height: CGFloat = 36
    static let minTabWidth: CGFloat = 64
    static let maxTabWidth: CGFloat = 220
    static let newTabButtonWidth: CGFloat = 32
    static let groupNewTabButtonWidth: CGFloat = 22
    static let sidebarToggleWidth: CGFloat = 40
}

/// Chrome-style tab strip for one window: group chips, tabs, a "+" per expanded
/// group, a "+" for ungrouped tabs and a trailing area that accepts drops at the end.
struct TabStripView: View {
    let windowID: UUID
    @Bindable var model: AppModel

    var body: some View {
        let window = model.window(windowID)
        let items = window?.stripItems ?? []
        let tabCount = items.filter { if case .tab = $0 { true } else { false } }.count

        GeometryReader { geo in
            let chipsWidth = items.reduce(CGFloat(0)) { sum, item in
                guard case .chip(let g, _) = item else { return sum }
                return sum + 30 + CGFloat(min(g.name.count, 20)) * 7
                    + (g.isCollapsed ? 22 : StripMetrics.groupNewTabButtonWidth)
            }
            let available = geo.size.width - StripMetrics.newTabButtonWidth - StripMetrics.sidebarToggleWidth - chipsWidth - 24
            let tabWidth = min(StripMetrics.maxTabWidth,
                               max(StripMetrics.minTabWidth, available / CGFloat(max(tabCount, 1))))

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(items) { item in
                            switch item {
                            case .chip(let group, let count):
                                GroupChipView(windowID: windowID, group: group, tabCount: count, model: model)
                                    .id(group.id)
                            case .tab(let tab):
                                TabItemView(windowID: windowID, tab: tab,
                                            group: tab.groupID.flatMap { window?.group($0) },
                                            isActive: window?.activeTabID == tab.id,
                                            width: tabWidth, model: model)
                                    // A visible gap where a group ends, so the ungrouped tabs
                                    // after it don't read as members of that group.
                                    .padding(.leading, endsGroupBefore(tab, in: items) ? 10 : 0)
                                    .id(tab.id)
                                if let g = tab.groupID, let group = window?.group(g), isLastOfGroup(tab, in: items) {
                                    GroupNewTabButton(group: group) { model.newTab(inGroup: g) }
                                }
                            }
                        }
                        // Follows the last tab; always opens an ungrouped tab at the end.
                        // Groups have their own "+" after their last tab.
                        NewTabButton { model.newTab(in: windowID, nextToActive: false) }
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, StripMetrics.sidebarToggleWidth)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
                    .background(TrailingDropArea(windowID: windowID, model: model))
                    .animation(.snappy(duration: 0.18), value: items)
                }
                .onChange(of: window?.activeTabID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
        .overlay(alignment: .trailing) { SidebarToggle(windowID: windowID, model: model) }
        .frame(height: StripMetrics.height)
        .background(.bar)
    }
}

/// Shows and hides the sidebar. While it is hidden, a new copy bounces the
/// button and leaves a dot until the sidebar is opened (like Safari's Downloads button).
private struct SidebarToggle: View {
    let windowID: UUID
    let model: AppModel
    @State private var unseen = false
    @State private var bounces = 0
    @State private var hovering = false

    var body: some View {
        let open = model.isSidebarOpen(windowID)
        Button { model.toggleSidebar(windowID) } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13))
                .symbolEffect(.bounce, value: bounces)
                .foregroundStyle(open ? Color.accentColor : .secondary)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            .offset(x: -3, y: 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(open ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(.bar) // covers tabs scrolled beneath it
        .onChange(of: model.clipboard.flashCount) { _, _ in
            guard !model.isSidebarOpen(windowID) else { return }
            bounces += 1
            withAnimation(.snappy) { unseen = true }
        }
        .onChange(of: open) { _, isOpen in if isOpen { withAnimation { unseen = false } } }
    }
}

/// True when `tab` is ungrouped and directly follows a group (its last tab or collapsed chip).
private func endsGroupBefore(_ tab: TerminalTab, in items: [StripItem]) -> Bool {
    guard tab.groupID == nil, let i = items.firstIndex(where: { $0.id == tab.id }), i > 0 else { return false }
    switch items[i - 1] {
    case .chip: return true
    case .tab(let prev): return prev.groupID != nil
    }
}

/// True when `tab` is grouped and the next strip item is not a tab of the same group.
private func isLastOfGroup(_ tab: TerminalTab, in items: [StripItem]) -> Bool {
    guard tab.groupID != nil, let i = items.firstIndex(where: { $0.id == tab.id }) else { return false }
    guard i + 1 < items.count, case .tab(let next) = items[i + 1] else { return true }
    return next.groupID != tab.groupID
}

/// Small "+" in the group's color after its last tab: adds a tab to that group.
private struct GroupNewTabButton: View {
    let group: TabGroup
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(group.color.color)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(group.color.color.opacity(hovering ? 0.2 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(group.name.isEmpty ? "New Tab in Group" : "New Tab in \(group.name)")
        .frame(width: StripMetrics.groupNewTabButtonWidth)
    }
}

private struct NewTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New Tab")
        .frame(width: StripMetrics.newTabButtonWidth)
    }
}

/// Empty space right of the tabs: drop target for "end of strip", double-click opens a tab.
private struct TrailingDropArea: View {
    let windowID: UUID
    let model: AppModel

    var body: some View {
        let hinted = model.activeDropHint == DropHint(windowID: windowID, target: .end)
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if hinted { DropBar(color: .accentColor) }
            }
            .onTapGesture(count: 2) { model.newTab(in: windowID, nextToActive: false) }
            .onDrop(of: [.smartTerminalTab, .smartTerminalGroup],
                    delegate: StripDropDelegate(windowID: windowID, model: model) { _ in .end })
    }
}

/// The vertical insertion marker shown while dragging.
struct DropBar: View {
    let color: Color
    var body: some View {
        Capsule().fill(color).frame(width: 3).padding(.vertical, 5)
    }
}

/// Shared drop handling: `resolve` maps the pointer position to a target.
struct StripDropDelegate: DropDelegate {
    let windowID: UUID
    let model: AppModel
    let resolve: (CGPoint) -> DropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        model.currentDrag != nil && info.hasItemsConforming(to: [.smartTerminalTab, .smartTerminalGroup])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Late updates can arrive after another window already took the drop.
        guard model.currentDrag != nil else {
            if model.dropHint != nil { model.dropHint = nil }
            return DropProposal(operation: .cancel)
        }
        let hint = resolve(info.location).map { DropHint(windowID: windowID, target: $0) }
        if model.dropHint != hint { model.dropHint = hint }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.dropHint?.windowID == windowID { model.dropHint = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload = model.currentDrag, let target = resolve(info.location) else {
            model.dropHint = nil
            return false
        }
        withAnimation(.snappy(duration: 0.2)) {
            model.performDrop(payload, into: windowID, at: target)
        }
        return true
    }
}
