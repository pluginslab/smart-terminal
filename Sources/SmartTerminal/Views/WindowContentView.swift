import SwiftUI
import SmartTerminalCore

struct WindowContentView: View {
    let windowID: UUID
    @Bindable var model: AppModel

    @AppStorage(TabLayout.defaultsKey) private var tabLayout: TabLayout = .sidebar

    var body: some View {
        switch tabLayout {
        case .strip:
            VStack(spacing: 0) {
                // The divider is drawn on the strip's own background: as a row of its own it
                // was a 1 pt gap that nothing painted, and in a translucent window the
                // desktop showed through it.
                TabStripView(windowID: windowID, model: model)
                    .overlay(alignment: .bottom) { Divider() }
                terminalArea
            }
            .frame(minWidth: 480, minHeight: 240)
        case .sidebar:
            TabSidebarLayout(windowID: windowID, model: model) { terminalArea }
                .frame(minWidth: 720, minHeight: 240)
        }
    }

    /// The resume bar, the terminal and the trailing panel: the same in both layouts.
    @ViewBuilder private var terminalArea: some View {
        let window = model.window(windowID)
        let shownTab = window?.activeTabID
        VStack(spacing: 0) {
            // A tab you open picks its saved Claude session (or tmux) back up by
            // itself, one at a time as you get to them, instead of all at once.
            Color.clear.frame(height: 0)
                .task(id: shownTab) {
                    if let shownTab, AppModel.resumesOnOpen { model.resumeAgent(shownTab) }
                }
            if let tab = window?.activeTab, let recovery = model.recovery(tab.id) {
                ResumeBar(recovery: recovery, command: recovery.command(cwd: tab.cwd),
                          resume: { model.resumeAgent(tab.id) }, dismiss: { model.dismissResume(tab.id) })
            }
            if let tab = window?.activeTab, let proposal = model.proposedCommands[tab.id] {
                ProposalBar(proposal: proposal, dismiss: { model.dismissProposal(tab.id) })
            }
            // Always present (never inside an if/else) so SwiftUI keeps the
            // container alive and only swaps the terminal view inside it.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TerminalContainer(tab: window?.activeTab, model: model)
                        .background(terminalBackground)
                    TerminalStatusBar(tab: window?.activeTab, model: model)
                }
                .frame(minWidth: 360)
                if model.isSidebarOpen(windowID) {
                    SidebarPanel(windowID: windowID, model: model)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.25), value: model.isSidebarOpen(windowID))
        }
    }

    /// The terminal paints its own (possibly translucent) background; underneath
    /// it we only add Terminal.app's background blur for "Clear" profiles.
    @ViewBuilder private var terminalBackground: some View {
        let profile = model.sessions.profile
        if profile.isTranslucent && profile.blur {
            VisualEffectBackground()
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Offered after a restart when Claude Code, or a tmux session, was running in this tab.
struct ResumeBar: View {
    @Environment(\.panelPalette) private var palette
    let recovery: TabRecovery
    /// What the button types, shown as its tooltip.
    let command: String
    let resume: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recovery.agent == nil ? "square.stack.3d.up" : "asterisk")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ClaudeGlyph.claudeOrange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(buttonTitle, action: resume)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help(command)
            Button("Dismiss", action: dismiss)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The tint alone let the desktop through in translucent windows; the strip's
        // own material goes underneath.
        .background(ClaudeGlyph.claudeOrange.opacity(0.12))
        .background(palette.map { AnyShapeStyle($0.bar) } ?? AnyShapeStyle(.bar))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func quoted(_ s: String?) -> String { s.map { "“\($0)”" } ?? "" }

    private var claude: String { "Claude session \(quoted(recovery.agent?.title))" }

    private var message: String {
        switch recovery {
        case .resume:
            "\(claude) was running here."
        case .reattach(let t, let agent):
            agent == nil ? "tmux session \(quoted(t.session)) is still running."
                : "tmux session \(quoted(t.session)) is still running, with the \(claude) inside."
        case .recreate(let t, let agent):
            agent == nil ? "tmux session \(quoted(t.session)) was attached here and has ended."
                : "\(claude) was running here in tmux \(quoted(t.session)), which has ended."
        case .reconnect(let r):
            "tmux \(quoted(r.session ?? "session")) on \(r.host ?? "the remote host") was attached here over ssh."
        }
    }

    private var buttonTitle: String {
        switch recovery {
        case .resume: "Resume"
        case .reattach: "Reattach"
        case .recreate(_, let agent): agent == nil ? "Recreate" : "Resume in tmux"
        case .reconnect: "Reconnect"
        }
    }
}

/// Over a tab Smart Terminal opened for a command Claude proposed: who asked and why.
/// The command itself is already typed at the prompt; Return runs it.
struct ProposalBar: View {
    @Environment(\.panelPalette) private var palette
    let proposal: ProposedCommand
    let dismiss: () -> Void
    static let tint = Color(red: 0x5F / 255, green: 0xB8 / 255, blue: 0xC9 / 255)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Self.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude in “\(proposal.askedBy)” asks you to run this. Press Return to run it, or edit it first.")
                    .font(.system(size: 12))
                if let reason = proposal.reason, !reason.isEmpty {
                    Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Self.tint.opacity(0.12))
        .background(palette.map { AnyShapeStyle($0.bar) } ?? AnyShapeStyle(.bar))
        .overlay(alignment: .bottom) { Divider() }
    }
}
