import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartTerminalCore

/// The colored label in front of a group's tabs. Click collapses/expands,
/// double-click (or the context menu) edits name and color, drag moves the whole group.
struct GroupChipView: View {
    let windowID: UUID
    let group: TabGroup
    let tabCount: Int
    let model: AppModel

    @State private var hovering = false

    private var hint: DropTarget? {
        model.activeDropHint?.windowID == windowID ? model.activeDropHint?.target : nil
    }

    private var memberNeedsAttention: Bool {
        model.window(windowID)?.tabs(in: group.id).contains { model.attention.contains($0.id) } ?? false
    }

    private var memberHasActivity: Bool {
        model.window(windowID)?.tabs(in: group.id).contains { model.activity.contains($0.id) } ?? false
    }

    var body: some View {
        HStack(spacing: 4) {
            if group.name.isEmpty {
                Circle().fill(group.color.onColor).frame(width: 6, height: 6)
            } else {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            if group.isCollapsed {
                Text("\(tabCount)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(group.color.onColor.opacity(0.25)))
                if memberNeedsAttention || memberHasActivity {
                    Circle().fill(memberNeedsAttention ? Color.orange : group.color.onColor)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .foregroundStyle(group.color.onColor)
        .padding(.horizontal, group.name.isEmpty ? 7 : 9)
        .frame(height: 20)
        .frame(maxWidth: 160)
        .fixedSize()
        .background(Capsule().fill(group.color.color.opacity(hovering ? 0.85 : 1)))
        .overlay {
            if hint == .intoGroup(group.id) {
                Capsule().strokeBorder(Color.primary.opacity(0.7), lineWidth: 2).padding(-3)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: StripMetrics.height - 8)
        .overlay(alignment: .leading) { if hint == .beforeGroup(group.id) { DropBar(color: .accentColor) } }
        .overlay(alignment: .trailing) { if hint == .afterGroup(group.id) { DropBar(color: .accentColor) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A drag moves views out from under the pointer without a hover-exit.
        .onChange(of: model.currentDrag) { _, _ in hovering = false }
        .onTapGesture(count: 2) { model.editingGroupID = group.id }
        .simultaneousGesture(TapGesture().onEnded {
            withAnimation(.snappy(duration: 0.2)) { model.toggleCollapsed(group.id) }
        })
        .popover(isPresented: Binding(
            get: { model.editingGroupID == group.id },
            set: { if !$0, model.editingGroupID == group.id { model.editingGroupID = nil } }
        ), arrowEdge: .bottom) {
            GroupEditor(group: group, windowID: windowID, model: model)
        }
        .onDrag {
            model.beginDrag(.group(group.id))
            return NSItemProvider(item: group.id.uuidString as NSString,
                                  typeIdentifier: UTType.smartTerminalGroup.identifier)
        }
        .onDrop(of: [.smartTerminalTab, .smartTerminalGroup],
                delegate: StripDropDelegate(windowID: windowID, model: model) { point in
                    resolveDrop(at: point)
                })
        .contextMenu { GroupContextMenu(group: group, windowID: windowID, model: model) }
        .help(group.name.isEmpty ? "Group: click to collapse, double-click to edit" : "\(group.name): click to collapse, double-click to edit")
    }

    /// Tab: left edge = ungrouped before the group, rest = into the group.
    /// Group: left half = before, right half = after.
    private func resolveDrop(at point: CGPoint) -> DropTarget? {
        switch model.currentDrag {
        case .tab:
            return point.x < 10 ? .beforeGroup(group.id) : .intoGroup(group.id)
        case .group(let dragged):
            if dragged == group.id { return nil }
            return point.x < 30 ? .beforeGroup(group.id) : .afterGroup(group.id)
        case nil:
            return nil
        }
    }
}

struct GroupEditor: View {
    let group: TabGroup
    let windowID: UUID
    let model: AppModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name this group", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit(); model.editingGroupID = nil }
                .onChange(of: name) { _, _ in commit() }
            HStack(spacing: 7) {
                ForEach(GroupColor.allCases, id: \.self) { c in
                    Button { model.updateGroup(group.id) { $0.color = c } } label: {
                        Circle().fill(c.color)
                            .frame(width: 18, height: 18)
                            .overlay {
                                if c == group.color {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(c.onColor)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(c.displayName)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                EditorAction("New Tab in Group", "plus") {
                    model.editingGroupID = nil; model.newTab(inGroup: group.id)
                }
                EditorAction("Ungroup", "rectangle.dashed") { model.editingGroupID = nil; model.ungroup(group.id) }
                EditorAction("Move Group to New Window", "macwindow.badge.plus") {
                    model.editingGroupID = nil; model.moveGroupToNewWindow(group.id)
                }
                EditorAction("Close Group", "xmark", role: .destructive) {
                    model.editingGroupID = nil; model.closeGroup(group.id)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { name = group.name; focused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != group.name { model.updateGroup(group.id) { $0.name = trimmed } }
    }
}

private struct EditorAction: View {
    let title: String
    let icon: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, _ icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.role = role; self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .onHover { hovering = $0 }
    }
}

struct GroupContextMenu: View {
    let group: TabGroup
    let windowID: UUID
    let model: AppModel

    var body: some View {
        Button("Edit Group…") { model.editingGroupID = group.id }
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { model.toggleCollapsed(group.id) }
        Menu("Color") {
            ForEach(GroupColor.allCases, id: \.self) { c in
                Button(c.displayName) { model.updateGroup(group.id) { $0.color = c } }
            }
        }
        Divider()
        Button("Ungroup") { model.ungroup(group.id) }
        Button("Move Group to New Window") { model.moveGroupToNewWindow(group.id) }
        Divider()
        Button("Close Group") { model.closeGroup(group.id) }
    }
}
