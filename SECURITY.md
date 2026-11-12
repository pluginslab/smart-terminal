# Security Policy

## Supported versions

Only the latest release is supported.

## Reporting a vulnerability

Please report privately rather than opening a public issue:

- GitHub: [private vulnerability reporting](https://github.com/pluginslab/smart-terminal/security/advisories/new)
- Email: hi@pluginslab.com

Expect an acknowledgement within a few days. Please include what you did, what
happened, and what you expected.

## What Smart Terminal touches

Useful context if you are assessing risk.

**It reads:**
- Claude Code's per-process session files (`<claude-config>/sessions/<pid>.json`) and
  the transcripts of sessions running in its own tabs
  (`<claude-config>/projects/…/<session-id>.jsonl`). That data is personal: it holds
  your folder paths and your prompts. It is only read, never modified. For the sidebar's
  Claude pane, each transcript is read once in full to total its token usage. Hovering a subagent
  reads its transcript (`<session>/subagents/agent-<id>.jsonl`) while the popover is open.
- Claude Code's `~/.claude.json`, only each project's `lastModelUsage`, to tell whether a
  folder last used the 1M-context model. At most once a minute per Claude tab.
- Terminal.app's preferences (`com.apple.Terminal`), to copy your default profile's
  font, colors and key bindings.
- Terminal.app's own key bindings (`Contents/Resources/keyMappings.plist` inside
  Terminal.app), when your default profile has none of its own.
- Process information for processes in its own tabs, and, during an import, in
  Terminal.app's tabs: working folder, command line and foreground process group,
  via `libproc`, `sysctl` and `ps`.
- The general clipboard (text, images and Finder file references), polled every 0.4 s for the clipboard history, and the
  name of the frontmost app at the time of a copy. It's kept in memory (last 50
  entries). Files copied in Finder are read only to draw a Quick Look thumbnail. Copies with the nspasteboard.org concealed or
  transient markers are skipped.

**It writes:**
- Its layout file, `~/Library/Application Support/SmartTerminal/layout.json`: window
  frames, group names and colors, tab names, working folders, and the id, title and
  command-line flags and folder of Claude sessions so they can be resumed, and the
  name (and `-L`/`-S` socket) of the tmux session a tab was attached to.
- The font-size preference and whether the sidebar is open, in its own user defaults.
- The clipboard, only when you click a clipboard history entry.
- A PNG in `$TMPDIR/SmartTerminal Clips/`, only when you paste an image entry into a tab.
  The folder is deleted at launch.

**It runs:**
- Your login shell (`$SHELL`) in each tab.
- `claude --resume <id> [original flags]`, typed into a tab's shell, only when you press
  **Resume** or during an import you started.
- `tmux list-clients -F …`, at most once a second while a tmux client is
  in front of a tab, to learn which pane it shows; `tmux has-session` once for a tab
  whose saved tmux session it offers to re-attach.
- `tmux attach`, or `tmux new-session` + `tmux send-keys` (with the resume command)
  + `tmux attach`, typed into a tab's shell, only when you press **Reattach** or
  **Resume in tmux**.
- `git status --porcelain=v2 --branch` and `git diff --shortstat HEAD` in each tab's
  folder, about every 4 seconds while the session list is on screen, with
  `GIT_OPTIONAL_LOCKS=0` so they never take the index lock. Read-only; they show the
  branch and the uncommitted diff in the tab's row.
- zsh, in each tab, with `ZDOTDIR` pointing at `~/Library/Application Support/SmartTerminal/zsh/`.
  Those four startup files (rewritten at every launch) source your own `.zshenv`,
  `.zprofile`, `.zshrc` and `.zlogin` unchanged. In a tab opened for a command Claude
  proposed they add one hook (below), which writes its report to a file in
  `browser-inbox/` next to them; the app reads and deletes it. Nothing in your home
  folder is changed. Other shells get none of this.
- During an import, and only for the tabs you checked: AppleScript that lists
  Terminal.app's tabs and types `/exit` into the Claude sessions being handed over,
  and `tmux detach-client` for tmux clients being moved.

**Commands Claude proposes.** `smart-terminal-mcp`, an MCP server Claude Code starts
when you add it, asks the app over the same local gate (below) to type a command into a
new tab. The app types it and never presses Return: only single lines of printable text
are accepted (no line break, tab, escape or other control character, no text-direction
control), so the command can't run itself or read differently than it runs. A zsh hook in
that tab reports the first command's exit status and command line to the app, which
hands them and the screen's text back to the session that asked.

**The agent gate.** At launch the app listens on `127.0.0.1` (a random port, never
another interface) and writes `chromium-gate.json` to its support folder, readable by
you alone (mode 0600), with that port and a random token. (The name is from when the
gate also handed out browsers, until 0.16.0.) Each shell in a tab gets
`SMART_TERMINAL_GATE` (that file's path) and `SMART_TERMINAL_TAB`. With the token, a
tool can propose a command in a tab and wait for its outcome; the gate offers nothing
else. Anyone who can read your files can read the token, as with any local credential:
it keeps out other users, not programs running as you.

**Network:** the app itself makes no network requests. Web links you ⌘-click open in
your default browser.

**It never:**
- opens a page you didn't ask for. Notifications are local, and links open only when you click them;
- modifies Claude Code's files;
- sends anything to a Terminal.app tab you did not select in the import sheet.

## Things we already think about

- The resume command is built from the recorded argv. Session-selecting flags and
  positional prompts are dropped, and every argument is shell-quoted
  (`AgentSessionRef.resumeCommand`, unit-tested).
- Claude sessions that are working are unchecked by default in the import sheet, so
  a hand-over never interrupts a running turn by accident.
- The development remote-control channel (`DebugChannel`) is compiled only into
  DEBUG builds, and even there it needs `SMART_TERMINAL_DEBUG=1`. Release builds do
  not contain it.
- Release builds use the hardened runtime. The one entitlement,
  `com.apple.security.automation.apple-events`, exists for the Terminal.app import.

If you find a way around any of these, that is exactly the kind of report we want.
