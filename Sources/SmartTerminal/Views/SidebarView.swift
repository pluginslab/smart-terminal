import AppKit
import SwiftUI

/// The trailing panel's content. The clipboard is its first tool; later tools
/// get a picker in the header.
struct SidebarView: View {
    let windowID: UUID
    let model: AppModel

    var body: some View {
        ClipboardPanel(windowID: windowID, model: model, history: model.clipboard)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sidebar as a flush column: square corners, a hairline on its leading edge
/// that meets the tab strip's divider, and a drag handle to resize. (SwiftUI's
/// `.inspector` draws a floating rounded panel meant to sit under a toolbar; with
/// our tab strip above it, its corner ran into the strip's divider.)
struct SidebarPanel: View {
    let windowID: UUID
    let model: AppModel

    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 440
    @AppStorage("sidebarWidth") private var width: Double = 280
    @State private var dragStart: Double?

    var body: some View {
        SidebarView(windowID: windowID, model: model)
            .frame(width: width)
            .background(.background.secondary)
            .overlay(alignment: .leading) {
                Divider()
                    .overlay {
                        // Wider invisible grab area over the hairline.
                        Color.clear.frame(width: 8).contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.columnResize.push() } else { NSCursor.pop() }
                            }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { g in
                                    let start = dragStart ?? width
                                    dragStart = start
                                    width = min(Self.maxWidth, max(Self.minWidth, start - g.translation.width))
                                }
                                .onEnded { _ in dragStart = nil })
                    }
            }
    }
}

// MARK: - Clipboard

struct ClipboardPanel: View {
    let windowID: UUID
    let model: AppModel
    let history: ClipboardHistory

    /// The row showing the "Copied" confirmation, and the one flashing as new.
    @State private var confirmedID: UUID?
    @State private var flashingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if history.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Copies Yet", systemImage: "doc.on.clipboard")
                } description: {
                    Text("Text you copy, including with pbcopy, shows up here. Click an entry to copy it again.")
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .onChange(of: history.flashCount) { _, _ in flash(history.lastAddedID) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Clipboard").font(.headline)
            if !history.entries.isEmpty {
                Text("\(history.entries.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !history.entries.isEmpty {
                Button("Clear") { withAnimation(.snappy) { history.clear() } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Remove all entries")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(history.entries) { entry in
                        ClipRow(entry: entry,
                                isConfirmed: confirmedID == entry.id,
                                isFlashing: flashingID == entry.id,
                                copy: { copy(entry) },
                                paste: { paste(entry) },
                                delete: { withAnimation(.snappy) { history.remove(entry) } })
                            .id(entry.id)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
                .padding(10)
            }
            .onChange(of: history.flashCount) { _, _ in
                if let id = history.lastAddedID { withAnimation { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }

    private func flash(_ id: UUID?) {
        withAnimation(.easeOut(duration: 0.15)) { flashingID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard flashingID == id else { return }
            withAnimation(.easeOut(duration: 0.8)) { flashingID = nil }
        }
    }

    private func copy(_ entry: ClipEntry) {
        history.restore(entry)
        withAnimation(.snappy(duration: 0.2)) { confirmedID = entry.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            guard confirmedID == entry.id else { return }
            withAnimation(.easeOut(duration: 0.3)) { confirmedID = nil }
        }
    }

    private func paste(_ entry: ClipEntry) {
        history.restore(entry)
        model.pasteClipboard(inWindow: windowID)
    }
}

struct ClipRow: View {
    let entry: ClipEntry
    let isConfirmed: Bool
    let isFlashing: Bool
    let copy: () -> Void
    let paste: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    private var lineCount: Int { entry.text.split(separator: "\n", omittingEmptySubsequences: false).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
            HStack(spacing: 5) {
                if isConfirmed {
                    // Confirm in place, like the Passwords app, instead of covering the text.
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                } else {
                    metadata
                }
                Spacer(minLength: 4)
                if lineCount > 4 {
                    Text("\(lineCount) lines").monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFlashing ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                 : AnyShapeStyle(hovering ? .quaternary : .quinary))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isFlashing || isConfirmed ? 0.6 : 0), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: copy)
        .help("Click to copy")
        .contextMenu {
            Button("Copy", action: copy)
            Button("Paste in Current Tab", action: paste)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Copy", copy)
        .accessibilityAction(named: "Paste in Current Tab", paste)
    }

    @ViewBuilder private var metadata: some View {
        sourceIcon
        if let source = entry.source {
            Text(source).lineLimit(1).truncationMode(.middle)
            Text("·")
        }
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(entry.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
        }
    }

    @ViewBuilder private var sourceIcon: some View {
        if let url = entry.appURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 14, height: 14)
        } else {
            Image(systemName: "terminal").font(.system(size: 10))
        }
    }
}
