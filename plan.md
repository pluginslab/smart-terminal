# Smart Terminal: Plan

## Architecture

```
SmartTerminalCore (library, no UI, fully unit-tested)
  Tab, TabGroup, GroupColor, WindowLayout   value types, Codable
  WindowLayout operations                    insert/move/close/group/ungroup/collapse
  invariants                                 groups are contiguous; no empty groups
  AppLayout + LayoutStore                    all windows; JSON save/load

SmartTerminal (executable, AppKit lifecycle + SwiftUI views)
  AppDelegate          menus, shortcuts, window creation, restore/save
  WindowController     one per window; NSHostingView(content)
  AppModel             @Observable; owns AppLayout; cross-window moves
  TabStripView         SwiftUI; chips + tabs + drag/drop delegates
  TerminalContainer    NSViewRepresentable; shows the active tab's session view
  SessionRegistry      tabID -> TerminalSession (keeps NSViews alive)
  TerminalSession      Phase 1: placeholder view. Phase 2: SwiftTerm LocalProcessTerminalView
```

### Key model choice: a flat list plus group ids (the Chrome model)
`WindowLayout.tabs: [Tab]`, where each `Tab.groupID: UUID?`, and
`WindowLayout.groups: [UUID: TabGroup]`.
Invariant: the tabs of a group are contiguous. Membership after a drop is decided
by where the tab lands: between two tabs of group G means it joins G; at a group
boundary it takes the group of the neighbour on the hovered side. This matches
Chrome, and it makes rendering a simple linear walk.

### Why the AppKit lifecycle (not a SwiftUI `WindowGroup`)
- Full control over creating windows at a point (for tear-off), their frames, and restoring them from our own JSON.
- Terminal NSViews must survive tab switches and moves between windows. A `SessionRegistry` outside the SwiftUI view tree owns them, and `NSViewRepresentable` just reparents them. This follows the libghostty/Calyx lesson: never let SwiftUI conditionals own terminal views.

### Drag and drop
- Payload: a custom UTType `com.pluginslab.smartterminal.tab` / `.group` carrying the id as a string. Every window runs in the same process, so a drop handler resolves the id in `AppModel`, which is how cross-window moves work for free.
- `.onDrag` + `DropDelegate` on each tab and chip. `dropUpdated` computes before/after from the x position and previews the move live, with animation.
- Tear-off (dragging to empty desktop) needs AppKit `NSDraggingSource.draggingSession(_:endedAt:operation:)`, so it is a stretch goal. v1 ships "Move to New Window".

## Milestones

### Phase 0: Foundation
- [x] 0.1 SwiftPM package (Core lib, App exe, Core tests), `scripts/bundle.sh` → `SmartTerminal.app`
- [x] 0.2 git init, .gitignore, CHANGELOG, VERSION
- [x] 0.3 Dev loop: `scripts/dev-run.sh` (isolated support dir) + `scripts/debug.sh` remote control & snapshots

### Phase 1: Tab system
- [x] 1.1 Core model + operations + invariants + tests (incl. 20×400-step fuzz)
- [x] 1.2 Layout persistence (JSON, debounced save, restore on launch) + tests
- [x] 1.3 App shell: AppDelegate, menus, multi-window, keyboard shortcuts
- [x] 1.4 Tab strip UI: tabs, active state, close buttons, "+" button, overflow scroll
- [x] 1.5 Rename (inline edit on double-click, context menu, ⌘⇧I)
- [x] 1.6 Groups UI: chip, color palette, rename, collapse, ungroup, close group
- [~] 1.7 Drag and drop: reorder, join/leave a group, drag a group, cross-window (built; needs hands-on test, cannot be automated here)
- [x] 1.8 Move tab/group to a new window (context menu); [~] tear-off drag (built via mouse-up watcher; needs hands-on test)
- [~] 1.9 Polish: animations, active tab matches the terminal color, dark/light (light mode untested)

### Phase 2: Terminal
- [x] 2.1 SwiftTerm dependency; TerminalSession wraps LocalProcessTerminalView; login shell in cwd
- [x] 2.2 Keep views alive across tab switches and window moves (registry + reparenting)
- [x] 2.3 Title (OSC 0/2, with `user@host:` parsing) + cwd (libproc polling + OSC 7) feed the automatic tab title and restore cwd
- [x] 2.4 New tab inherits cwd and group; clean exit closes the tab, a failing one stays open
- [x] 2.5 Font + zoom, theme (**imported from Terminal.app's default profile**), copy/paste, clear, find (SwiftTerm's find bar)
- [x] 2.6 Bell/activity indicators on tabs and chips
- [x] 2.7 Close confirmation for running processes (tab, group, window, quit)

### Phase 3: MVP for agent work (decided 2026-09-24)
- [x] 3.1 Resume Claude after relaunch: persist each tab's Claude session id + title; on restore the tab offers (or runs) `claude --resume <id>`
- [x] 3.2 "Needs you" notifications: macOS notification when a background Claude finishes or asks for permission (busy→idle and Claude's own OSC 9/777 alerts); click focuses the tab; Dock badge = number waiting
- [x] 3.5 Import tabs from Terminal.app (Shell menu): AppleScript scan → Claude handed over (/exit there, --resume here), tmux re-attached here + detached there, shells reopened; grouped by project folder; busy Claude sessions unchecked by default
- [ ] 3.3 ⌘P quick switcher: fuzzy search over tab names, group names, Claude titles, last prompts, cwd, across all windows
- [ ] 3.4 Daily-driver polish: app icon, release build → /Applications, settings pane (font, profile: Terminal.app default vs built-in), fixes from real use

### Later (not v1)
- tmux-aware Claude detection: inside tmux the pty's foreground job is the tmux client, so Claude's session and title are invisible. Resolve via `tmux list-clients` → the client's active pane pid → a Claude descendant → session file; enable tmux title passthrough
- Agents overview (menu bar or side panel listing every Claude session by status); deferred until after living with the MVP
- Session persistence via a daemon, split panes, settings window, libghostty swap.

## Risks
| Risk | Mitigation |
|---|---|
| SwiftUI drag and drop is flaky on macOS (previews, drop-exit events) | Keep the logic in Core (tested). Fall back to an AppKit tab strip if the UX suffers. |
| NSView reparenting glitches in NSViewRepresentable | The registry owns the views; the container swaps a subview in `updateNSView`. |
| Shell environment (PATH, locale) differs from Terminal.app | Spawn `$SHELL -l`, set TERM=xterm-256color, COLORTERM, LANG. |
