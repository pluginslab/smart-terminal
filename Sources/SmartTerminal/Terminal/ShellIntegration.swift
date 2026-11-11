import AppKit
import Foundation
import SmartTerminalCore

/// zsh startup files that load yours unchanged and add one hook: a tab opened for a
/// command Claude proposed reports how that command went. The same trick VS Code's
/// terminal uses: `ZDOTDIR` points at these, each one sources your file of the same
/// name, so nothing in your home folder is touched.
///
/// The report lands as a file in the app's inbox folder, which the app watches.
enum ShellIntegration {
    static let supportDir: URL = {
        if let override = ProcessInfo.processInfo.environment["SMART_TERMINAL_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartTerminal", isDirectory: true)
    }()
    static let zshDir = supportDir.appendingPathComponent("zsh", isDirectory: true)
    // The name dates from when `open` sent web pages here too (until 0.16.0).
    static let inboxDir = supportDir.appendingPathComponent("browser-inbox", isDirectory: true)

    /// Tabs opened to run a command Claude proposed: their shell reports how the first
    /// command went (`SMART_TERMINAL_PROPOSAL`, see .zshenv). Main thread only.
    nonisolated(unsafe) static var proposals: [UUID: String] = [:]

    /// Environment for a tab's shell. Only zsh gets the integration; every shell learns its tab.
    static func environment(shell: String, tabID: UUID, inherited: [String: String]) -> [String: String] {
        // Any shell: which tab it's in, and where agent tools reach the app
        // (AgentGate; the file is readable by you alone and holds the token).
        var common = ["SMART_TERMINAL_TAB": tabID.uuidString,
                      "SMART_TERMINAL_GATE": AgentGate.infoFile.path]
        if let id = proposals[tabID] { common["SMART_TERMINAL_PROPOSAL"] = id }
        guard (shell as NSString).lastPathComponent == "zsh" else { return common }
        var env = common.merging(["ZDOTDIR": zshDir.path,
                                  "SMART_TERMINAL_INBOX": inboxDir.path]) { a, _ in a }
        // Your own ZDOTDIR, if you have one, is where your files are read from. Started
        // from a Smart Terminal tab, the app inherits that tab's shim folder as ZDOTDIR:
        // take the folder it was standing in for, never a shim (they'd source each other
        // until zsh gives up).
        let own = [inherited["SMART_TERMINAL_USER_ZDOTDIR"], inherited["ZDOTDIR"]]
            .compactMap { $0 }.first { !$0.isEmpty && !isShim($0) }
        if let own { env["SMART_TERMINAL_USER_ZDOTDIR"] = own }
        return env
    }

    /// Ours, or any Smart Terminal's (another copy of the app, a dev build).
    static func isShim(_ path: String) -> Bool {
        if path == zshDir.path { return true }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path) { return true }
        // Shims written before the marker existed (0.10.0).
        let zshenv = try? String(contentsOf: dir.appendingPathComponent(".zshenv"), encoding: .utf8)
        return zshenv?.contains("Smart Terminal shell integration") == true
    }

    /// Marks a folder as a Smart Terminal shim, for the checks above and in .zshenv.
    static let marker = ".smart-terminal-shim"

    /// Writes the startup files (every launch, so an update replaces them) and the inbox.
    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: zshDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let body = name == ".zshenv" ? zshenv : wrapper(name)
            try? body.write(to: zshDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try? "".write(to: zshDir.appendingPathComponent(marker), atomically: true, encoding: .utf8)
    }

    /// Runs first, in every zsh: remember both folders, load yours, hook a proposal tab.
    private static let zshenv = #"""
    # Smart Terminal shell integration. Loads your own zsh files unchanged and reports
    # how a command Claude proposed went. Rewritten at launch.
    _st_zdotdir=$ZDOTDIR
    : ${SMART_TERMINAL_USER_ZDOTDIR:=$HOME}
    # Never a shim folder, ours or another Smart Terminal's: they would source each other.
    [[ $SMART_TERMINAL_USER_ZDOTDIR == $_st_zdotdir || -e $SMART_TERMINAL_USER_ZDOTDIR/.smart-terminal-shim ]] &&
      SMART_TERMINAL_USER_ZDOTDIR=$HOME
    export SMART_TERMINAL_USER_ZDOTDIR
    ZDOTDIR=$SMART_TERMINAL_USER_ZDOTDIR
    [[ -r $ZDOTDIR/.zshenv ]] && source $ZDOTDIR/.zshenv
    [[ $ZDOTDIR != $_st_zdotdir ]] && SMART_TERMINAL_USER_ZDOTDIR=$ZDOTDIR
    ZDOTDIR=$_st_zdotdir

    # A tab Smart Terminal opened for a command Claude proposed: when the first command
    # you run there ends, tell the app its exit status and the line as it ran. First in
    # precmd_functions, so $? is still that command's.
    if [[ -n $SMART_TERMINAL_PROPOSAL && -o interactive && -d $SMART_TERMINAL_INBOX ]]; then
      _st_proposal_preexec() { _st_proposal_cmd=$1 }
      _st_proposal_precmd() {
        local st=$?
        [[ -n $_st_proposal_cmd ]] || return 0
        local f=$SMART_TERMINAL_INBOX/.$SMART_TERMINAL_PROPOSAL.$$
        print -r -- "$st"$'\n'"$_st_proposal_cmd" >| $f && mv -f $f $SMART_TERMINAL_INBOX/$SMART_TERMINAL_PROPOSAL.done
        preexec_functions=(${preexec_functions:#_st_proposal_preexec})
        precmd_functions=(${precmd_functions:#_st_proposal_precmd})
        unset SMART_TERMINAL_PROPOSAL _st_proposal_cmd
      }
      preexec_functions=(_st_proposal_preexec $preexec_functions)
      precmd_functions=(_st_proposal_precmd $precmd_functions)
    fi
    """#

    /// .zprofile, .zshrc, .zlogin: load yours from your folder, then keep reading from ours.
    private static func wrapper(_ name: String) -> String {
        """
        # Smart Terminal shell integration: loads your \(name). Rewritten at launch.
        _st_zdotdir=$ZDOTDIR
        ZDOTDIR=$SMART_TERMINAL_USER_ZDOTDIR
        [[ -r $ZDOTDIR/\(name) ]] && source $ZDOTDIR/\(name)
        ZDOTDIR=$_st_zdotdir
        """
    }
}

/// Watches the inbox folder: a proposed command's tab reports there when it ran.
@MainActor
final class ShellInbox {
    private var source: DispatchSourceFileSystemObject?
    private let finished: (String, String) -> Void

    /// `finished`: a proposed command's tab reported (proposal id, the file's text).
    init(finished: @escaping (String, String) -> Void) {
        self.finished = finished
        let fd = Darwin.open(ShellIntegration.inboxDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        drain() // reports that arrived while the app was quit
    }

    private func drain() {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: ShellIntegration.inboxDir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in all {
            switch file.pathExtension {
            case "done":
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                try? fm.removeItem(at: file)
                finished(file.deletingPathExtension().lastPathComponent, text)
            case "url":
                // `open <url>` in a shell started before 0.16.0 (a tmux session lives
                // on): "<tab> <url>". The page goes where macOS sends it now.
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
                try? fm.removeItem(at: file)
                if Date.now.timeIntervalSince(created) < 60,
                   let link = text.split(separator: " ", maxSplits: 1).last.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
                   let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }
}
