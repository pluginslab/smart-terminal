import AppKit

/// Owns every live TerminalSession, keyed by tab id. Sessions are created
/// lazily the first time a tab is shown, so a restored layout with many tabs
/// only spawns shells for tabs the user actually opens.
@MainActor
final class SessionRegistry {
    weak var model: AppModel?
    private var sessions: [UUID: TerminalSession] = [:]

    /// Imported from Terminal.app's default profile when available.
    let profile = TerminalProfile.load(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

    /// User zoom (⌘+/⌘-); nil means the profile's own size.
    private(set) var fontSizeOverride: CGFloat? = {
        let saved = UserDefaults.standard.double(forKey: "fontSize")
        return saved > 0 ? CGFloat(saved) : nil
    }()

    var fontSize: CGFloat { fontSizeOverride ?? profile.font.pointSize }

    func existing(_ tabID: UUID) -> TerminalSession? { sessions[tabID] }

    /// Returns the tab's session, starting its shell if needed.
    func session(for tabID: UUID, cwd: String?) -> TerminalSession {
        if let s = sessions[tabID] { return s }
        let s = TerminalSession(tabID: tabID, profile: profile, fontSize: fontSizeOverride)
        s.onChange = { [weak self] s in
            self?.model?.sessionUpdated(tabID: s.tabID, autoTitle: s.autoTitle, cwd: s.currentDirectory)
            self?.model?.agentUpdated(tabID: s.tabID, agent: s.agent, ref: s.agentRef)
        }
        s.onTerminalTitle = { [weak self] s in
            self?.model?.titleBarChanged(tabID: s.tabID, info: TitleBarInfo(
                programTitle: s.shellTitle, command: s.commandLine, cols: s.gridSize.cols, rows: s.gridSize.rows))
        }
        s.onBell = { [weak self] s in self?.model?.markAttention(s.tabID) }
        s.onOutput = { [weak self] s in self?.model?.markActivity(s.tabID) }
        s.onExit = { [weak self] s, code in self?.sessionExited(s, code: code) }
        sessions[tabID] = s
        s.start(cwd: cwd)
        return s
    }

    func currentDirectory(of tabID: UUID) -> String? { sessions[tabID]?.currentDirectory }

    func runningCommand(of tabID: UUID) -> String? { sessions[tabID]?.runningCommand }

    func terminate(_ tabID: UUID) {
        guard let s = sessions.removeValue(forKey: tabID) else { return }
        s.terminate()
        s.view.removeFromSuperview()
    }

    func terminateAll() {
        sessions.keys.forEach(terminate)
    }

    // MARK: - Font

    /// nil resets to the profile's size.
    func setFontSize(_ size: CGFloat?) {
        fontSizeOverride = size.map { min(max($0, 8), 36) }
        if let v = fontSizeOverride {
            UserDefaults.standard.set(Double(v), forKey: "fontSize")
        } else {
            UserDefaults.standard.removeObject(forKey: "fontSize")
        }
        let font = NSFont(descriptor: profile.font.fontDescriptor, size: fontSize) ?? profile.font
        sessions.values.forEach { $0.view.font = font }
    }

    // MARK: - Exit

    /// A clean exit (`exit`, ^D) closes the tab, like Terminal.app's default.
    /// A failing shell stays open so the error can be read.
    private func sessionExited(_ s: TerminalSession, code: Int32?) {
        if code == 0 || code == nil {
            model?.closeTab(s.tabID)
        } else {
            s.view.feed(text: "\r\n\u{1b}[2m[Process exited with code \(code!)]\u{1b}[0m\r\n")
        }
    }
}
