import SwiftUI
import SmartTerminalCore

/// Lists what was found in Terminal.app, grouped by folder, with checkboxes.
struct ImportSheet: View {
    let candidates: [ImportCandidate]
    let onImport: ([ImportCandidate]) -> Void
    let onCancel: () -> Void
    @State private var selected: Set<String>

    init(candidates: [ImportCandidate], onImport: @escaping ([ImportCandidate]) -> Void, onCancel: @escaping () -> Void) {
        self.candidates = candidates
        self.onImport = onImport
        self.onCancel = onCancel
        _selected = State(initialValue: Set(candidates.filter(\.selectedByDefault).map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Tabs from Terminal.app").font(.headline)
            Text("Each tab opens here in the same folder, grouped by project. Claude sessions are handed over: they get /exit in Terminal.app and resume here. tmux sessions are re-attached here and detached there.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(TerminalImportPlan.groups(candidates), id: \.name) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).font(.subheadline.weight(.semibold))
                            ForEach(group.members) { c in row(c) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, maxHeight: 380)
            HStack {
                Button(selected.count == candidates.count ? "Select None" : "Select All") {
                    selected = selected.count == candidates.count ? [] : Set(candidates.map(\.id))
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Import \(selected.count)") {
                    onImport(candidates.filter { selected.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func row(_ c: ImportCandidate) -> some View {
        Toggle(isOn: Binding(get: { selected.contains(c.id) },
                             set: { if $0 { selected.insert(c.id) } else { selected.remove(c.id) } })) {
            HStack(spacing: 8) {
                Image(systemName: icon(c)).frame(width: 16).foregroundStyle(tint(c))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label(c)).lineLimit(1)
                    Text(detail(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func icon(_ c: ImportCandidate) -> String {
        switch c.kind {
        case .claude: "asterisk"
        case .tmux: "square.stack.3d.up"
        case .shell: "terminal"
        }
    }

    private func tint(_ c: ImportCandidate) -> Color {
        if case .claude = c.kind { return ClaudeGlyph.claudeOrange }
        return .secondary
    }

    private func label(_ c: ImportCandidate) -> String {
        switch c.kind {
        case .claude(let ref, _, _): ref.title ?? "Claude Code"
        case .tmux(let session): session
        case .shell: c.tabTitle ?? c.folderName
        }
    }

    private func detail(_ c: ImportCandidate) -> String {
        let place = c.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? c.tty
        switch c.kind {
        case .claude(_, _, let busy):
            return (busy ? "Claude is working now: handing over will stop it mid-turn · " : "Claude, handed over · ") + place
        case .tmux: return "tmux, re-attached · " + place
        case .shell(let cmd):
            if let cmd, !cmd.isEmpty { return "New shell here (\(cmd) stays in Terminal.app) · " + place }
            return "New shell · " + place
        }
    }
}
