import SwiftUI
import SmartTerminalCore

struct WindowContentView: View {
    let windowID: UUID
    @Bindable var model: AppModel

    var body: some View {
        let window = model.window(windowID)
        VStack(spacing: 0) {
            // The divider is drawn on the strip's own background: as a row of its own it
            // was a 1 pt gap that nothing painted, and in a translucent window the
            // desktop showed through it.
            TabStripView(windowID: windowID, model: model)
                .overlay(alignment: .bottom) { Divider() }
            if let tab = window?.activeTab, let ref = model.resumableSession(tab.id) {
                ResumeBar(ref: ref, resume: { model.resumeAgent(tab.id) }, dismiss: { model.dismissResume(tab.id) })
            }
            // Always present (never inside an if/else) so SwiftUI keeps the
            // container alive and only swaps the terminal view inside it.
            HStack(spacing: 0) {
                TerminalContainer(tab: window?.activeTab, model: model)
                    .background(terminalBackground)
                if model.isSidebarOpen(windowID) {
                    SidebarPanel(windowID: windowID, model: model)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.25), value: model.isSidebarOpen(windowID))
        }
        .frame(minWidth: 480, minHeight: 240)
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

/// Offered after a restart when Claude Code was running in this tab.
struct ResumeBar: View {
    let ref: AgentSessionRef
    let resume: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "asterisk")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ClaudeGlyph.claudeOrange)
            Text("Claude session \(ref.title.map { "“\($0)”" } ?? "") was running here.")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Resume", action: resume)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help(ref.resumeCommand)
            Button("Dismiss", action: dismiss)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ClaudeGlyph.claudeOrange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
