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
  your folder paths and your prompts. It is only read, never modified.
- Terminal.app's preferences (`com.apple.Terminal`), to copy your default profile's
  font and colors.
- Process information for processes in its own tabs, and, during an import, in
  Terminal.app's tabs: working folder, command line and foreground process group,
  via `libproc`, `sysctl` and `ps`.

**It writes:**
- Its layout file, `~/Library/Application Support/SmartTerminal/layout.json`: window
  frames, group names and colors, tab names, working folders, and the id, title and
  command-line flags of Claude sessions so they can be resumed.
- The font-size preference in its own user defaults.

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
