import AppKit
import SwiftUI
import QuickLookThumbnailing

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
    private static let top = "top"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if history.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Copies Yet", systemImage: "doc.on.clipboard")
                } description: {
                    Text("Text, images and files you copy, including with pbcopy, show up here. Click an entry to copy it again.")
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
                    Color.clear.frame(height: 0).id(Self.top)
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
                withAnimation { proxy.scrollTo(Self.top, anchor: .top) }
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
        if let text = history.pasteText(for: entry) { model.paste(text, inWindow: windowID) }
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

    private var lineCount: Int {
        guard case .text(let s) = entry.content else { return 0 }
        return s.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var pasteLabel: String {
        switch entry.content {
        case .text: "Paste in Current Tab"
        case .files(let urls): urls.count == 1 ? "Paste Path in Current Tab" : "Paste Paths in Current Tab"
        case .image: "Paste as File in Current Tab"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
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
                if let detail { Text(detail).monospacedDigit().lineLimit(1) }
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
            Button(pasteLabel, action: paste)
            if case .files(let urls) = entry.content {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Copy", copy)
        .accessibilityAction(named: pasteLabel, paste)
    }

    @ViewBuilder private var preview: some View {
        switch entry.content {
        case .text(let s):
            Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
        case .image:
            if let img = entry.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator))
                    .frame(maxWidth: .infinity)
            }
        case .files(let urls):
            FilesPreview(urls: urls)
        }
    }

    /// Right side of the metadata line.
    private var detail: String? {
        switch entry.content {
        case .text: return lineCount > 4 ? "\(lineCount) lines" : nil
        case .image(let d, let type, let px):
            let kind = type == .png ? "PNG" : type == .tiff ? "TIFF" : (type.rawValue.split(separator: ".").last?.uppercased() ?? "")
            return "\(kind) · \(Int(px.width))×\(Int(px.height)) · \(d.count.formatted(.byteCount(style: .file)))"
        case .files(let urls):
            return urls.count > 1 ? "\(urls.count) items" : nil
        }
    }

    @ViewBuilder private var metadata: some View {
        sourceIcon
        if let source = entry.source {
            Text(source).lineLimit(1).truncationMode(.middle)
            Text("·")
        }
        // A 10 s tick keeps every label within 10 s of true, focused or not. Cheap:
        // one short Text per row, and SwiftUI only redraws when the string changes.
        TimelineView(.periodic(from: .now, by: 10)) { context in
            Text(Self.age(of: entry.date, now: context.date))
        }
    }

    /// "now" under a minute, then "5 min ago", "3 hr ago", then the date.
    /// No seconds: a seconds count is stale one second after it's drawn.
    static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "now"
        case ..<60: return "\(minutes) min ago"
        case ..<(24 * 60): return "\(minutes / 60) hr ago"
        default: return date.formatted(date: .abbreviated, time: .shortened)
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

/// Finder copies: a QuickLook thumbnail for one file, a stack of names for several.
private struct FilesPreview: View {
    let urls: [URL]

    var body: some View {
        if urls.count == 1, let url = urls.first {
            VStack(alignment: .leading, spacing: 6) {
                FileThumbnail(url: url, maxSize: CGSize(width: 240, height: 140))
                    .frame(maxWidth: .infinity)
                FileName(url: url)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(urls.prefix(4), id: \.self) { url in
                    HStack(spacing: 6) {
                        FileThumbnail(url: url, maxSize: CGSize(width: 18, height: 18)).frame(width: 18, height: 18)
                        FileName(url: url)
                    }
                }
                if urls.count > 4 {
                    Text("and \(urls.count - 4) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FileName: View {
    let url: URL
    var body: some View {
        Text(url.lastPathComponent)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1).truncationMode(.middle)
            .help(url.path)
    }
}

/// QuickLook thumbnail (image, PDF, video frame…), falling back to the Finder icon.
private struct FileThumbnail: View {
    let url: URL
    let maxSize: CGSize
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: maxSize.width, maxHeight: maxSize.height)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: maxSize, scale: scale,
                                                       representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = rep.nsImage
            }
        }
    }
}
