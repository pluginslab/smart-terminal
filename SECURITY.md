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
  font and colors.
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
  `.zprofile`, `.zshrc` and `.zlogin` unchanged, then define an `open` function. For a
  single http(s) URL it writes `<tab id> <url>` to a file in `browser-inbox/` next to
  them, which the app reads and deletes; every other use runs `command open`. Nothing
  in your home folder is changed. Other shells get none of this.
- During an import, and only for the tabs you checked: AppleScript that lists
  Terminal.app's tabs and types `/exit` into the Claude sessions being handed over,
  and `tmux detach-client` for tmux clients being moved.

**Network:** the app itself makes no network requests. The browser pane loads the pages
you open in it (by `open <url>` in a tab, ⌘-clicking a link, or the address bar), with
WebKit, the engine Safari uses. Its cookies and site data are kept in the app's own
WebKit data store, shared by its tabs.

**It never:**
- loads a page you didn't ask for. Notifications are local, and links open only when you click them;
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
