import AppKit
import SwiftTerm
import SmartTerminalCore

/// SwiftTerm view with hooks for bell, output activity and appearance changes.
final class SmartTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    var onOutput: (() -> Void)?

    override func bell(source: Terminal) {
        onBell?()
    }

    /// SwiftTerm paints the default background through `layer.backgroundColor`,
    /// which is a no-op if set before the layer exists; re-apply once hosted.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let bg = nativeBackgroundColor
        nativeBackgroundColor = bg
    }

    private var lastOutputSignal = Date.distantPast

    /// Every chunk from the pty. Only output that contains a line break counts as
    /// activity: full-screen redraws (tmux's status-line clock, a TUI repainting a
    /// cell) are cursor-addressed and carry none, so they no longer re-mark a tab
    /// moments after you left it. Measured: idle tmux redraw 133 B / 0 LF, a
    /// printed line inside tmux 31 B / 1 LF. Throttled, since chunks can arrive
    /// thousands of times a second.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        #if DEBUG
        if ProcessInfo.processInfo.environment["SMART_TERMINAL_LOG_OUTPUT"] == "1" {
            let lf = slice.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            DebugLog.write("output \(slice.count)B lf=\(lf)")
        }
        #endif
        guard slice.contains(10) else { return }
        let now = Date()
        if now.timeIntervalSince(lastOutputSignal) > 0.5 {
            lastOutputSignal = now
            onOutput?()
        }
    }

}

/// One shell in one tab. Owns the view for the tab's whole life so it survives
/// tab switches and moves between windows.
@MainActor
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let tabID: UUID
    let view: SmartTerminalView
    private(set) var shellTitle: String?
    private(set) var currentDirectory: String?
    private(set) var foregroundProcess: String?
    private(set) var isRunning = false
    /// Claude Code session in the foreground, if any.
    private(set) var agent: AgentSnapshot?
    /// What to persist so this Claude session can be resumed after a restart.
    var agentRef: AgentSessionRef? {
        guard let agent, let id = agent.sessionID else { return nil }
        return AgentSessionRef(sessionID: id, title: agent.title, arguments: claude.arguments)
    }
    private let claude = ClaudeWatcher()

    var onChange: ((TerminalSession) -> Void)?
    /// Title-bar inputs changed: program title (every spinner frame), command, grid size.
    var onTerminalTitle: ((TerminalSession) -> Void)?
    /// Terminal.app-style process part: "caffeinate ◂ claude --dangerously-skip-permissions", or "-zsh".
    private(set) var commandLine: String?
    var gridSize: (cols: Int, rows: Int) {
        let t = view.getTerminal()
        return (t.cols, t.rows)
    }
    private var lastGlyphStatus: AgentStatus?
    var onExit: ((TerminalSession, Int32?) -> Void)?
    var onBell: ((TerminalSession) -> Void)?
    var onOutput: ((TerminalSession) -> Void)?

    private var pollTimer: Timer?
    private var reportedOnce = false
    private let shellPath: String

    init(tabID: UUID, profile: TerminalProfile, fontSize: CGFloat?) {
        self.tabID = tabID
        self.shellPath = Self.userShell()
        self.view = SmartTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.processDelegate = self
        view.wantsLayer = true
        profile.apply(to: view, fontSize: fontSize)
        view.onBell = { [weak self] in self.map { $0.onBell?($0) } }
        view.onOutput = { [weak self] in self.map { $0.onOutput?($0) } }
    }

    func start(cwd: String?) {
        guard !isRunning else { return }
        var isDir: ObjCBool = false
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil }
            ?? Self.homeDirectory
        currentDirectory = dir
        let shellName = (shellPath as NSString).lastPathComponent
        view.startProcess(executable: shellPath, args: [], environment: Self.environment(shell: shellPath),
                          execName: "-" + shellName, // leading dash = login shell, like Terminal.app
                          currentDirectory: dir)
        isRunning = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Not synchronously: start() runs inside SwiftUI's updateNSView.
        DispatchQueue.main.async { [weak self] in self?.poll() }
    }

    /// Kills the shell. Callbacks are dropped first: an exit we caused must not
    /// feed back into the model (e.g. closing tabs while the app quits).
    func terminate() {
        onExit = nil
        onChange = nil
        onTerminalTitle = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if isRunning { view.terminate() }
        isRunning = false
    }

    var shellPid: pid_t { view.process?.shellPid ?? 0 }

    /// Name of a non-shell command running in the foreground, e.g. "vim".
    var runningCommand: String? {
        guard isRunning, let pgid = ProcessInspector.foregroundGroup(ptyFD: view.process.childfd),
              pgid != shellPid else { return nil }
        return ProcessInspector.name(of: pgid)
    }

    /// Title shown when the user has not renamed the tab.
    var autoTitle: String {
        let folder = currentDirectory.map(Self.prettyFolder) ?? "Terminal"
        if let agent {
            return agent.title ?? "Claude · \(folder)"
        }
        let base: String
        switch shellTitle.flatMap({ ShellTitle.classify($0, localHostNames: Self.localHostNames) }) {
        case .remote(let host, let path)?: base = "\(host): \(Self.prettyFolder(path))"
        case .custom(let t)?: base = t
        case .localPrompt?, nil: base = folder
        }
        if let cmd = foregroundProcess, !base.contains(cmd) { return "\(base) · \(cmd)" }
        return base
    }

    private static let localHostNames = [ProcessInfo.processInfo.hostName, Host.current().localizedName ?? ""]

    private func poll() {
        guard isRunning else { return }
        let cwd = ProcessInspector.cwd(of: shellPid) ?? currentDirectory
        let fg = runningCommand
        let pgid = ProcessInspector.foregroundGroup(ptyFD: view.process.childfd).flatMap { $0 == shellPid ? nil : $0 }
        let newAgent = claude.update(foregroundPGID: pgid, terminalTitle: shellTitle)
        let newCommand = Self.describeCommand(leader: pgid, shell: shellPath)
        if newCommand != commandLine {
            commandLine = newCommand
            onTerminalTitle?(self)
        }
        // Always report the first poll: a tab that starts in its folder and whose shell
        // never sets a title would otherwise keep the placeholder name.
        if !reportedOnce || cwd != currentDirectory || fg != foregroundProcess || newAgent != agent {
            reportedOnce = true
            currentDirectory = cwd
            foregroundProcess = fg
            agent = newAgent
            onChange?(self)
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { onTerminalTitle?(self) }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            let glyphStatus = ClaudeTitle.parse(title)?.status
            let statusFlipped = glyphStatus != lastGlyphStatus
            shellTitle = title
            lastGlyphStatus = glyphStatus
            onTerminalTitle?(self) // every frame, so the window title animates like Terminal.app's
            // Spinner frames arrive several times a second; only a busy/idle flip needs a re-read.
            if statusFlipped, glyphStatus != nil { poll() }
            onChange?(self)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            // OSC 7 sends a file:// URL.
            guard let directory else { return }
            let path = URL(string: directory)?.path ?? directory
            guard !path.isEmpty, path != currentDirectory else { return }
            currentDirectory = path
            onChange?(self)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            isRunning = false
            pollTimer?.invalidate()
            onExit?(self, exitCode)
        }
    }

    /// "newest-child ◂ leader args…" for a foreground job, "-zsh" when the shell is in front.
    static func describeCommand(leader: pid_t?, shell: String) -> String {
        guard let leader, let args = ProcessInspector.arguments(of: leader) else {
            return "-" + (shell as NSString).lastPathComponent
        }
        var line = args.joined(separator: " ")
        if line.count > 90 { line = String(line.prefix(89)) + "…" }
        if let child = ProcessInspector.newestChild(ofLeader: leader), let name = ProcessInspector.name(of: child) {
            return "\(name) ◂ \(line)"
        }
        return line
    }

    // MARK: - Environment

    static func userShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func environment(shell: String) -> [String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        // CLAUDE_CONFIG_DIR: the app watches Claude's files there, so the shells' `claude` must use it too.
        for key in ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "CLAUDE_CONFIG_DIR"] {
            if let v = inherited[key] { env[key] = v }
        }
        env["HOME"] = Self.homeDirectory
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["SHELL"] = shell
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = inherited["LANG"] ?? "en_US.UTF-8"
        env["TERM_PROGRAM"] = "SmartTerminal"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// `$HOME` when set, like a shell, else the account's home. (`NSHomeDirectory()`
    /// ignores `$HOME`; honouring it lets the README demo run in a clean home folder.)
    static var homeDirectory: String {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }

    static func prettyFolder(_ path: String) -> String {
        if path == homeDirectory || path == "~" { return "~" }
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }
}
