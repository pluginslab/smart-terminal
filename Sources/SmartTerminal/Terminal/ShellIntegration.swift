import Foundation
import SmartTerminalCore

/// zsh startup files that load yours unchanged and add an `open` that shows web
/// pages in the tab's own browser pane. The same trick VS Code's terminal uses:
/// `ZDOTDIR` points at these, each one sources your file of the same name, so
/// nothing in your home folder is touched. `ZDOTDIR` stays set for child shells,
/// which is how Claude Code's Bash tool (it snapshots a fresh zsh) gets `open` too.
///
/// `open` takes over only for one http(s) URL; every other use goes to macOS.
/// The URL lands as a file in the app's inbox folder, which the app watches.
enum ShellIntegration {
    static let supportDir: URL = {
        if let override = ProcessInfo.processInfo.environment["SMART_TERMINAL_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartTerminal", isDirectory: true)
    }()
    static let zshDir = supportDir.appendingPathComponent("zsh", isDirectory: true)
    static let inboxDir = supportDir.appendingPathComponent("browser-inbox", isDirectory: true)

    /// Environment for a tab's shell. Only zsh is integrated; other shells get nothing.
    static func environment(shell: String, tabID: UUID, inherited: [String: String]) -> [String: String] {
        guard (shell as NSString).lastPathComponent == "zsh" else { return [:] }
        var env = ["ZDOTDIR": zshDir.path,
                   "SMART_TERMINAL_TAB": tabID.uuidString,
                   "SMART_TERMINAL_INBOX": inboxDir.path]
        // Your own ZDOTDIR, if you have one, is where your files are read from.
        if let own = inherited["ZDOTDIR"], own != zshDir.path { env["SMART_TERMINAL_USER_ZDOTDIR"] = own }
        return env
    }

    /// Writes the startup files (every launch, so an update replaces them) and the inbox.
    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: zshDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let body = name == ".zshenv" ? zshenv : wrapper(name)
            try? body.write(to: zshDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// Runs first, in every zsh: remember both folders, load yours, define `open`.
    private static let zshenv = #"""
    # Smart Terminal shell integration. Loads your own zsh files unchanged and adds
    # an `open` that shows web pages in the tab's browser pane. Rewritten at launch.
    _st_zdotdir=$ZDOTDIR
    : ${SMART_TERMINAL_USER_ZDOTDIR:=$HOME}
    export SMART_TERMINAL_USER_ZDOTDIR
    ZDOTDIR=$SMART_TERMINAL_USER_ZDOTDIR
    [[ -r $ZDOTDIR/.zshenv ]] && source $ZDOTDIR/.zshenv
    [[ $ZDOTDIR != $_st_zdotdir ]] && SMART_TERMINAL_USER_ZDOTDIR=$ZDOTDIR
    ZDOTDIR=$_st_zdotdir

    _st_define_open() {
      unalias open 2>/dev/null
      open() {
        if [[ $# -eq 1 && ( $1 == http://* || $1 == https://* ) && -n $SMART_TERMINAL_TAB && -d $SMART_TERMINAL_INBOX ]]; then
          # Inside tmux the tab id is the tmux server's, from whichever tab started it:
          # send none, and the page opens in the tab you're looking at.
          local f=$SMART_TERMINAL_INBOX/.$$.$RANDOM tab=$SMART_TERMINAL_TAB
          [[ -n $TMUX ]] && tab=-
          print -r -- "$tab $1" >| $f && mv -f $f $f.url
        else
          command open "$@"
        fi
      }
    }
    _st_define_open
    """#

    /// .zprofile, .zshrc, .zlogin: load yours from your folder, then keep reading
    /// from ours. `open` is redefined after .zshrc in case yours aliased it.
    private static func wrapper(_ name: String) -> String {
        """
        # Smart Terminal shell integration: loads your \(name). Rewritten at launch.
        _st_zdotdir=$ZDOTDIR
        ZDOTDIR=$SMART_TERMINAL_USER_ZDOTDIR
        [[ -r $ZDOTDIR/\(name) ]] && source $ZDOTDIR/\(name)
        ZDOTDIR=$_st_zdotdir
        \(name == ".zshrc" ? "(( $+functions[_st_define_open] )) && _st_define_open" : "")
        """
    }
}

/// Watches the inbox folder and hands each `open` request to the app.
@MainActor
final class BrowserInbox {
    private var source: DispatchSourceFileSystemObject?
    private let handle: (BrowserRequest) -> Void

    init(handle: @escaping (BrowserRequest) -> Void) {
        self.handle = handle
        let fd = Darwin.open(ShellIntegration.inboxDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        drain() // clears requests left from before a restart
    }

    private func drain() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: ShellIntegration.inboxDir, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.pathExtension == "url" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
            try? fm.removeItem(at: file)
            // One left over from before a restart is stale: don't pop a page up for it.
            guard Date.now.timeIntervalSince(created) < 60, let request = BrowserRequest.parse(text) else { continue }
            handle(request)
        }
    }
}
