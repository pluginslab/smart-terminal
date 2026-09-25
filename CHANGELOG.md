# Changelog

## [0.7.0] - 2026-09-25
- Sidebar panes: icons in the sidebar's header row switch between Clipboard and Claude Code, like Xcode's inspector tabs. The pane's title (and the clipboard's count and Clear) share that row. A copy arriving while another pane is showing puts a dot on the clipboard icon.
- Claude Code pane, following the current tab:
  - Live status: an animated asterisk and a turn timer while Claude works, "Needs you" with the reason when it waits, time since the last reply when idle.
  - Context meter: tokens in context and a ring against the context window. Replies log the model without its `[1m]` suffix, so the window comes from, in order: `/context` or `/model` output in the transcript; a context already past 200k; the folder's last-used model in `~/.claude.json`; else an assumed 200k, shown as "~200k". The tooltip names the source.
  - "Resumed" instead of "Started" for a session opened with `--resume` or `--continue`.
  - Session tokens: output, input, cache read, cache write.
  - Subagents, newest first: a spinning asterisk and live timer while running (with a "2 running" badge), then a check with duration, tokens and tool calls, or a red cross if it failed. Background subagents finish through their task notification, wherever it lands: a normal message, several in one message, or queued while Claude was mid-turn (a `queue-operation` enqueue, delivered later as a `queued_command` attachment). Duration, tokens and tool calls come from the notification's own stats. The default `general-purpose` type isn't shown. One launched before a `--resume` that never reported back shows as "didn't finish" instead of running forever. The list starts over when a new prompt launches subagents and all previous ones completed; a running or failed one keeps the list, so it isn't missed.
  - Hover a subagent for a 600×400 popover: its latest tool call ("Now · Bash(git status)"), then its activity as a mini terminal in Claude Code's style (its task, what it says, each tool call with the first lines of its result), following the newest line. Its transcript is found through the `.meta.json` Claude writes next to it, so running subagents work too, and only new lines are read, once a second, while the popover is open.
  - The model's name ("Opus 5.5") heads the context card.
  - Prompts typed, last turn duration, session start.
- Token totals count each API message once. A response is logged as one line per content block, each repeating the same usage, so counting lines would inflate totals about 2.3×.
- Each transcript is read once in full, off the main thread and one at a time (11 MB in 0.23 s), then followed as it grows.
- README screenshot is now taken from the app by `scripts/demo-screenshot.sh`, with invented data: a clean `HOME` (`demo/home`), a throwaway `CLAUDE_CONFIG_DIR`, and `demo/fake-claude.swift` standing in for `claude`. It shows tab groups (one collapsed), a Claude tab at work and the sidebar's Claude pane with subagents. The drawn mock (`scripts/mock-screenshot.py`) is gone.
- Fix: a new tab that starts in its folder and whose shell never sets a title was named "Terminal"; the first poll now always reports.
- The app honours `$HOME` for its default folder, and passes `CLAUDE_CONFIG_DIR` to its shells (it already read Claude's files from there).
- Debug commands `snapshotClaude`, `showSubagent`, `pane`, `subagentPopover`, `toggleGroup`, `typeSlow`, `activate`.

## [0.6.0] - 2026-09-25
- Sidebar (⌃⌘S, or the button at the right end of the tab strip): a resizable panel on the right, flush with the tab strip (drag its left edge; the width is remembered).
- Its first tool is a clipboard history. Every copy lands at the top and flashes: text (including `pbcopy`), images (screenshots, Copy Image, with size and format) and files copied in Finder (Quick Look previews). With the sidebar closed, its button bounces and shows a dot instead. Click an entry to copy it again (it confirms "Copied" in place); right-click to paste it into the current tab (files as quoted paths; images saved as a temporary PNG and pasted as its path, which Claude Code attaches) or delete it. Ages read "now", then "5 min ago", "3 hr ago", then the date; no seconds, which go stale the moment they're drawn. Holds the last 50 copies, in memory only. Copies marked concealed or transient (password managers) are skipped.
- Clicking an image file copied in Finder also puts the image itself on the clipboard (as PNG), so ⌃V in Claude Code pastes it; before, the clipboard held only the file reference and Claude reported no image.
- Fix: a 1 pt see-through line between the tab strip and the terminal in translucent windows (the divider was its own row with nothing painted behind it; it's now drawn on the strip).
- Every expanded group gets its own "+" in its color, right after its last tab: it opens a tab at the end of that group, in the folder of the group's last tab.
- The "+" at the end of the strip now always opens an ungrouped tab at the end. It used to join whichever group the selected tab was in, so the result depended on the selection. ⌘T still opens the tab next to the current one.
- Debug commands `sidebar`, `snapshotSidebar`, `restoreClip`, `pasteClip` and `newTabInGroup`.

## [0.5.1] - 2026-09-24
- CI: actions/checkout v5 (Node 20 deprecation).
- Fix: the activity dot never cleared on tmux tabs. tmux redraws its status-line clock every few seconds, which counted as output and re-marked the tab right after you left it. Activity now requires a line break in the output (idle tmux redraw: 133 B, no line break; a printed line: 31 B, one line break).
- A visible gap where a group ends, so ungrouped tabs right after a group no longer look like members of it.
- README modelled on wims: story, full usage, how it works, privacy, configuration, limitations; mocked screenshot.
- SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, .editorconfig, CI (build + tests on macOS 26).
- Planning docs moved to docs/.

## [0.5.0] - 2026-09-24
First public release: signed, notarized, universal (Apple silicon + Intel), macOS 26+.
- App icon, About panel (version, build, credits), MIT licence.
- Tab keeps Claude's live ◐/✳ status prefix when renamed.
- Hardened runtime + Apple Events entitlement; debug remote-control channel compiled out of release builds.

## [0.1.0] - development
- Import tabs from Terminal.app (Claude handover, tmux re-attach, grouped by folder).
- Resume Claude sessions after relaunch; "needs you" notifications and Dock badge; waiting status.
- Terminal.app-style window title: folder — live program title (animated) — process ◂ command — cols×rows.
- Claude Code-aware tabs: session name (/rename, AI title) as the tab title, working/waiting glyph, tooltip with last prompt and PR.
- Move a tab within its group with ⌃←/⌃→ (⌃⌥←/⌃⌥→ alias).
- Initial tab system: tabs, rename, named/colored groups, drag and drop, multi-window, layout persistence.
