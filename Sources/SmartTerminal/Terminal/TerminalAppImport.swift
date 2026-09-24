import AppKit
import SmartTerminalCore

/// Finds tabs open in Terminal.app and moves them over: Claude Code sessions are
/// handed over (/exit there, --resume here), tmux clients re-attached here and
/// detached there, plain shells reopened in the same folder.
@MainActor
enum TerminalAppImport {
    enum ScanError: LocalizedError {
        case notRunning
        case appleScript(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: "Terminal.app is not running."
            case .appleScript(let m): "Could not read Terminal.app's tabs: \(m)"
            }
        }
    }

    // MARK: - Scan

    static func scan() throws -> [ImportCandidate] {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first != nil else {
            throw ScanError.notRunning
        }
        let source = """
        set out to ""
        set sep to character id 9 -- inside `tell Terminal`, the word tab means Terminal's tab object
        tell application "Terminal"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set out to out & (id of w) & sep & i & sep & (tty of t) & sep & (custom title of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            throw ScanError.appleScript((error?[NSAppleScript.errorMessage] as? String) ?? "unknown error")
        }
        let tmuxClients = tmuxClientSessions()
        return result.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let wid = Int(f[0]), let idx = Int(f[1]) else { return nil }
            return classify(tty: f[2], windowID: wid, tabIndex: idx, customTitle: f[3], tmuxClients: tmuxClients)
        }
    }

    private struct TTYProcess { let pid: pid_t; let pgid: pid_t; let tpgid: pid_t; let comm: String }

    private static func classify(tty: String, windowID: Int, tabIndex: Int, customTitle: String,
                                 tmuxClients: [String: String]) -> ImportCandidate? {
        let procs = processes(onTTY: tty)
        // Terminal.app starts `login`, which starts the login shell ("-zsh").
        guard let shell = procs.first(where: { $0.comm.hasPrefix("-") }) ?? procs.first else { return nil }
        let cwd = ProcessInspector.cwd(of: shell.pid)
        let title = customTitle.isEmpty ? nil : customTitle
        let fg = shell.tpgid

        func candidate(_ kind: ImportCandidate.Kind, cwd: String?) -> ImportCandidate {
            ImportCandidate(tty: tty, terminalWindowID: windowID, terminalTabIndex: tabIndex,
                            cwd: cwd, customTitle: title, kind: kind)
        }

        guard fg > 0, fg != shell.pgid else { return candidate(.shell(runningCommand: nil), cwd: cwd) }
        let args = ProcessInspector.arguments(of: fg) ?? []

        if let record = ClaudeWatcher.sessionRecord(pid: fg) {
            let aiTitle = title.flatMap(ClaudeTitle.parse)?.title
            let ref = AgentSessionRef(sessionID: record.sessionId, title: aiTitle, arguments: args)
            return candidate(.claude(ref: ref, pid: fg, busy: record.agentStatus == .busy), cwd: record.cwd ?? cwd)
        }
        if args.first == "tmux", let session = tmuxClients[tty] {
            return candidate(.tmux(session: session), cwd: cwd)
        }
        return candidate(.shell(runningCommand: args.joined(separator: " ")), cwd: cwd)
    }

    private static func processes(onTTY tty: String) -> [TTYProcess] {
        let name = (tty as NSString).lastPathComponent
        let out = run("/bin/ps", ["-t", name, "-o", "pid=,pgid=,tpgid=,comm="]) ?? ""
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard f.count == 4, let pid = pid_t(f[0]), let pgid = pid_t(f[1]), let tpgid = pid_t(f[2]) else { return nil }
            return TTYProcess(pid: pid, pgid: pgid, tpgid: tpgid, comm: (f[3] as NSString).lastPathComponent)
        }
    }

    /// client tty → session name, from the running tmux server (if any).
    private static func tmuxClientSessions() -> [String: String] {
        guard let tmux = which("tmux"),
              let out = run(tmux, ["list-clients", "-F", "#{client_tty}\t#{session_name}"]) else { return [:] }
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            if f.count == 2 { map[f[0]] = f[1] }
        }
        return map
    }

    // MARK: - Import

    struct Report { var tabs = 0; var handedOver = 0; var tmux = 0; var failed: [String] = [] }

    /// Creates the tabs (grouped by folder) in `windowID`, then moves the live bits over.
    static func perform(_ selected: [ImportCandidate], into windowID: UUID, model: AppModel,
                        completion: @escaping (Report) -> Void) {
        var report = Report()
        var pairs: [(ImportCandidate, TerminalTab)] = []
        let groups = TerminalImportPlan.groups(selected).map { group in
            (name: group.name, tabs: group.members.map { c -> TerminalTab in
                var agent: AgentSessionRef?
                if case .claude(let ref, _, _) = c.kind { agent = ref }
                let tab = TerminalTab(customTitle: c.tabTitle, autoTitle: c.folderName, cwd: c.cwd, agentSession: agent)
                pairs.append((c, tab))
                return tab
            })
        }
        model.update(windowID) { $0.importGroups(groups) }
        report.tabs = pairs.count

        var pending = 0
        func finishOne() { pending -= 1; if pending == 0 { completion(report) } }
        pending += 1 // guard so completion runs once, after the loop

        for (c, tab) in pairs {
            switch c.kind {
            case .shell:
                break // opens lazily in its folder when first shown
            case .tmux(let session):
                let s = model.sessions.session(for: tab.id, cwd: tab.cwd)
                s.view.send(txt: "tmux attach -t \(AgentSessionRef.shellQuote(session))\r")
                pending += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // Now attached here too; drop Terminal.app's client.
                    if let tmux = which("tmux"), run(tmux, ["detach-client", "-t", c.tty]) != nil {
                        report.tmux += 1
                    } else {
                        report.failed.append("tmux \(session): could not detach Terminal.app's client")
                    }
                    finishOne()
                }
            case .claude(_, let pid, _):
                pending += 1
                sendToTerminal("/exit", windowID: c.terminalWindowID, tabIndex: c.terminalTabIndex)
                waitForExit(pid: pid, timeout: 20) { exited in
                    if exited {
                        model.resumeAgent(tab.id)
                        report.handedOver += 1
                    } else {
                        report.failed.append("Claude “\(tab.agentSession?.title ?? c.folderName)” did not exit in Terminal.app; use Resume once it has")
                    }
                    finishOne()
                }
            }
        }
        finishOne()
    }

    private static func sendToTerminal(_ text: String, windowID: Int, tabIndex: Int) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\" to do script \"\(escaped)\" in tab \(tabIndex) of window id \(windowID)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("SmartTerminal: do script failed: \(error)") }
    }

    private static func waitForExit(pid: pid_t, timeout: TimeInterval, done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if kill(pid, 0) != 0 { done(true); return }
            if Date() > deadline { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
        }
        check()
    }

    // MARK: - Helpers

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// GUI apps get a minimal PATH; look in the usual places.
    static func which(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
