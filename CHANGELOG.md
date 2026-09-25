# Changelog

## [0.6.0] - 2026-09-25
- Sidebar (⌃⌘S, or the button at the right end of the tab strip): a resizable panel on the right, flush with the tab strip (drag its left edge; the width is remembered).
- Its first tool is a clipboard history. Every copy lands at the top and flashes: text (including `pbcopy`), images (screenshots, Copy Image, with size and format) and files copied in Finder (Quick Look previews). With the sidebar closed, its button bounces and shows a dot instead. Click an entry to copy it again (it confirms "Copied" in place); right-click to paste it into the current tab (files as quoted paths; images saved as a temporary PNG and pasted as its path, which Claude Code attaches) or delete it. Ages read "now", then "5 min ago", "3 hr ago", then the date; no seconds, which go stale the moment they're drawn. Holds the last 50 copies, in memory only. Copies marked concealed or transient (password managers) are skipped.
- Fix: a 1 pt see-through line between the tab strip and the terminal in translucent windows (the divider was its own row with nothing painted behind it; it's now drawn on the strip).
- Debug commands `sidebar`, `snapshotSidebar` and `pasteClip`.

## [0.5.2] - 2026-09-25
- Every expanded group gets its own "+" in its color, right after its last tab: it opens a tab at the end of that group, in the folder of the group's last tab.
- The "+" at the end of the strip now always opens an ungrouped tab at the end. It used to join whichever group the selected tab was in, so the result depended on the selection. ⌘T still opens the tab next to the current one.

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
