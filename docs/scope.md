# Smart Terminal: Scope

A native macOS terminal that feels like Terminal.app, with a tab system borrowed
from Chrome: tabs can be renamed and gathered into **named, colored, collapsible
groups**, and dragged between groups and windows.

## Why
Terminal.app, iTerm2, Ghostty and WezTerm have no named/colored tab groups. The
closest option, [TabTerm](https://github.com/halvis82/TabTerm), runs terminals
inside Chrome to borrow Chrome's groups. With 10+ tabs open across several
projects, finding "the one running the API logs" is the real pain.

## Decisions (interview, 2026-09-24)
| Topic | Decision |
|---|---|
| Tab placement | Horizontal Chrome-style strip under the titlebar. Groups are colored name-chips; clicking a chip collapses or expands the group. |
| Terminal engine | SwiftTerm (`LocalProcessTerminalView`), already proven in `../polyterm`. |
| Persistence | **Layout only.** Windows, groups (name, color, collapsed), tab order, custom titles and each tab's cwd are restored. Shells start fresh in the saved cwd. |
| Windows | Multi-window. Tabs and whole groups can move between windows, or out into a new window. |
| Platform | macOS 26+, Swift 6.2, SwiftPM (no .xcodeproj), non-sandboxed. |

## In scope: v1

### Phase 1: Tab system (the product)
- Tab strip: new, close, select, reorder by drag, overflow scrolling.
- Rename a tab (double-click, or context menu). A custom title overrides the shell title; clearing it restores the automatic one.
- Groups: create from a tab, name, pick from 9 Chrome colors, collapse/expand, ungroup, close the whole group.
- Drag and drop:
  - reorder tabs within the strip
  - drop a tab into or out of a group (the position decides membership)
  - drag a whole group by its chip
  - drag a tab or group into another window's strip
  - "Move to New Window" (context menu). Drag-out tear-off is a stretch goal.
- Keyboard: ⌘T, ⌘W, ⌘N, ⌘1…⌘9, ⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[, ⌘⇧G (group the current tab).
- Layout persistence to `~/Library/Application Support/SmartTerminal/layout.json`.
- The tab body is a placeholder until Phase 2.

### Phase 2: Terminal inside each tab
- SwiftTerm view per tab, kept alive across tab switches and window moves (reparented, never recreated).
- Login shell (`$SHELL -l`) in the tab's cwd. Track cwd via OSC 7, and take the title from OSC 0/2.
- Automatic tab title: the shell title, else the cwd's folder name.
- A new tab inherits the active tab's cwd and group (Terminal.app behavior).
- Font (SF Mono / Menlo) plus ⌘+ / ⌘- / ⌘0, a sensible default theme, copy/paste, ⌘K clear, ⌘F find.
- Bell or activity in a background tab shows a dot on the tab and tints the group chip.
- Confirm before closing a tab or group that is running a non-shell process.

## Out of scope (v1)
- Keeping processes alive across quit (daemon or tmux). This could be a later phase.
- Split panes, profiles/settings UI beyond font and theme, SSH manager, AI features.
- Mac App Store and sandboxing.
- libghostty. The engine sits behind a small seam, so a swap stays possible.

## Success criteria
1. With 15 tabs in 4 groups, any tab can be found in under 2 seconds by color or name.
2. Drag-and-drop never loses a tab or leaves a group non-contiguous (unit-tested model invariants).
3. Quitting and relaunching restores the identical layout.
4. Day-to-day shell use (vim, htop, claude, ssh) works like Terminal.app.
