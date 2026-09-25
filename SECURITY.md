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
  command-line flags of Claude sessions so they can be resumed.
- The font-size preference and whether the sidebar is open, in its own user defaults.
- The clipboard, only when you click a clipboard history entry.
- A PNG in `$TMPDIR/SmartTerminal Clips/`, only when you paste an image entry into a tab.
  The folder is deleted at launch.

**It runs:**
- Your login shell (`$SHELL`) in each tab.
- `claude --resume <id> [original flags]`, typed into a tab's shell, only when you press
  **Resume** or during an import you started.
- During an import, and only for the tabs you checked: AppleScript that lists
  Terminal.app's tabs and types `/exit` into the Claude sessions being handed over,
  and `tmux detach-client` for tmux clients being moved.

**It never:**
- makes network requests. Notifications are local, and links open only when you click them;
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
