# Smart Terminal: Progress Log

Newest first. Each entry lists what was done, what is next, and any open issues.

## 2026-09-24: v0.5.0 release (public)
- Checklist from Apple's docs and current guides: Developer ID signing, hardened runtime, secure timestamp, notarytool, staple, DMG notarized + stapled, `spctl` check, `NSHumanReadableCopyright`, `LSApplicationCategoryType`, About panel, icon, licence. Sparkle deferred.
- `scripts/release.sh`: tests → per-arch release builds + `lipo` (SwiftPM's multi-`--arch` build fails on SwiftTerm's build plugin) → bundle signed with the Developer ID (`--options runtime --timestamp`, `SmartTerminal.entitlements` = apple-events) → notarize and staple the app → DMG (with an /Applications link) signed, notarized and stapled → `spctl` accepted, "Notarized Developer ID" → sha256. It refuses to run without a CHANGELOG entry for VERSION.
- Uses the existing `fujifilm-notary` keychain profile and the "Developer ID Application: PictoMessages, Lda." identity (same as fujifilm-webcam). Unlike fujifilm-webcam, stapling is fine here: there are no nested system-extension bundles to break the seal.
- Icon: generated with Nano Banana 2 (`gemini-3.1-flash-image`, `scripts/gen-icon-art.py`, four concepts; Marcel picked "stacked glass folders"). It ships **full-bleed square** (macOS applies the mask). `scripts/compose-icon.swift` builds the icns; `--preview` renders a rounded mockup.
- The About panel shows version, build (UTC timestamp), credits, the GitHub link and the SwiftTerm acknowledgement. The debug channel is compiled out of release builds (`#if DEBUG`).
- The tab keeps Claude's live ◐/✳ glyph when renamed. Inside tmux, Claude is not visible yet (plan: tmux-aware detection).
- Before going public, tests and docs were scrubbed of personal and client context (host names, client and session names). The public repo starts from a single v0.5.0 commit; the full development history stays on the local branch `dev-history`.

## 2026-09-24: MVP phase 3: resume, notifications, Terminal.app import
**3.1 Resume Claude after relaunch.** `TerminalTab.agentSession` (`AgentSessionRef`: sessionID, title, original argv) is persisted. It is cleared only when Claude exits while we watch (/exit, ^C), so a quit or crash keeps it. After a relaunch, a bar reads "Claude session “X” was running here" with [Resume] (⌘⇧R) and [Dismiss]. The resume command keeps the original flags and drops session pickers and positional prompts (`resumeCommand`, tested). Verified: kill app → relaunch → bar → Resume ran `claude --dangerously-skip-permissions --resume fe9d…` with the same title; /exit then cleared the ref.

**3.2 "Needs you" notifications.** Found in Claude's source: the session file's `status` can be **`waiting`** plus `waitingFor` ("permission prompt", "input needed", "dialog open", …), which the title glyph can't show. Also found that for an unknown `TERM_PROGRAM`, Claude's `auto` notification channel returns `no_method_available` and sends nothing, so we rely on the session file rather than OSC 9. Busy→idle means "Claude finished"; →waiting means "Claude needs you" (with sound). A notification posts only when the tab isn't visible to you (app inactive, or not the key window's active tab); clicking it reveals the tab. The Dock badge counts tabs waiting on you. The tab glyph for waiting is an orange speech bubble with "!". Verified: `waiting waitingFor=permission prompt` detected live; badge 1 → cleared on click. (Marcel denied notifications once by accident and re-enabled them; status 2 = authorized.)
- Apparent "first turn missed" was a notification click clearing the mark; `debug.log` now records every transition and clear with its reason.

**3.5 Import tabs from Terminal.app** (new; Marcel's request, decisions: hand over Claude, group by project folder, tmux attach here + detach there).
- The scan uses AppleScript (window id, tab index, tty, custom title), `ps -t` (login shell → cwd, foreground job), the Claude session file (pid → sessionId, cwd, status) and `tmux list-clients` (client tty → session).
- Gotcha: inside `tell application "Terminal"`, the word `tab` is Terminal's tab class, not a tab character.
- The import sheet lists candidates grouped by folder with checkboxes; **busy Claude sessions start unchecked**, including the session doing the building.
- Verified on throwaway windows only: Claude `/exit` via `do script` → old pid gone → `claude --resume e24e…` running here under its AI title; tmux `st-import-test` attached here with Terminal.app's client detached; `failed=[]`. A dry-run scan of a real Terminal.app setup found every Claude session and tmux client, with correct session ids, titles, flags and folder groups; the busy session running this build was unchecked.
- Builds are now signed with the "Apple Development: Marcel Schmitz" identity so Automation and notification grants survive rebuilds (ad-hoc signatures change every build).
- New debug commands: `state`, `resume`, `importScan <file>` (dry run), `importTTYs <tty,tty>` (real import limited to given ttys).

## 2026-09-24: Terminal.app-style window title
Marcel's request: program title updates (Claude Code's ✳ and ◐◓◑◒ animation) must show in the window title bar, as in Terminal.app. His reference: `smart-terminal — ◐ Terminal.app replica with tab groups — caffeinate ◂ claude --dangerously-skip-permissions — 280×57`.
- The window title is now `[group —] [tab name —] folder — <program's OSC title verbatim> — <newest child> ◂ <job argv> — cols×rows`, and `-zsh` when the shell is in front. It updates on every title frame, so the spinner animates in the title bar.
- The argv comes from `sysctl KERN_PROCARGS2`. The "newest child" is chosen by **start time**, not pid: pids wrap, and in a real Claude tree the MCP servers have higher pids than `caffeinate`.
- A busy/idle glyph flip re-reads Claude state immediately; plain spinner frames don't.
- Verified in the test instance: `smart-terminal — ◐ Four sentences about tabs — caffeinate ◂ claude --dangerously-skip-permissions — 108×24`, with the frames alternating ◐/◑, then ✳ when done, then `… — -zsh — …` after exit.

## 2026-09-24: Claude Code-aware tab names
Investigated what Claude Code (2.1.281) exposes (see `Sources/SmartTerminalCore/ClaudeCode.swift` for the field notes):
- **Terminal title (OSC):** `◐◓◑◒ <title>` while busy and `✳ <title>` when idle, set once there is an AI title. Before the first prompt, only zsh's command-line title shows.
- **`~/.claude/sessions/<pid>.json`:** `status` (busy/idle/shell), `sessionId`, `cwd`, `name` + `nameSource`. The key is Claude's pid, which is the foreground process group of our pty, so detection is exact. `derived` names (`smart-terminal-92`) are noise; `auto` names and user names are good.
- **`~/.claude/projects/<cwd with non-alnum→"-">/<sessionId>.jsonl`:** appended `custom-title` (/rename), `ai-title`, `agent-name`, `last-prompt`, `pr-link`, `cost-state`. Files reach 40MB and title entries can be 12MB apart, so we scan backwards in growing windows, then tail from the offset.
- The process name is useless (`2.1.281`, the versioned binary).

Built
- Core: `ClaudeTitle.parse`, `ClaudeSessionRecord`, `ClaudeTranscriptState` (the line-level parser), and `AgentSnapshot.make`, which sets the priority: /rename > AI title > agent name > non-derived session name > terminal title. Otherwise the fallback is "Claude · <folder>". 44 tests.
- App: `ClaudeWatcher` per session (session JSON read every 1s only while a non-shell process is in the foreground; transcript tailed incrementally; respects `CLAUDE_CONFIG_DIR`). The tab glyph is a spinning orange ✱ while working, a grey ✱ when idle, and a filled orange ✱ when it **finished in the background and is waiting for you** (also bounces the Dock). The tooltip shows status, AI title, last prompt, PR link and folder. Claude's spinner no longer triggers the activity dot.
- Verified end to end in a test instance: "Claude · smart-terminal" → AI title "What a pty is" → `/rename` "pty explainer" → exit back to "smart-terminal" → `claude --resume` back to "pty explainer".

Tooling
- `scripts/test-run.sh` launches a separate **test instance** (a bundle copy plus its own layout dir); `SMART_TERMINAL_DEBUG_ID=test scripts/debug.sh …` targets it. Each instance has its own debug channel, so automated checks no longer restart the dev instance Marcel is using. New debug commands: `key <code> <mods>` (real key events) and `resize w h`.

## 2026-09-24: Hands-on feedback round 1
Marcel's test results: 1 (drag reorder/groups) works, 5 (popover and look) is all good.
- **Fixed: a drop indicator stayed on a tab after a cross-window drag.** Two causes are covered. (a) Late `dropUpdated` calls could re-set the hint after another window took the drop; hints now render only while a drag is in flight (`activeDropHint`), and a late update clears them. (b) A hover state could stay stuck, because the drag moves views without a hover-exit; hover resets whenever a drag starts or ends.
- **Added: ⌃← / ⌃→ move the active tab within its group only** (`WindowLayout.shift`, with 3 new tests). It beeps at the group's edge, and an ungrouped tab never jumps into a group. macOS reserves ⌃←/⌃→ for Spaces (enabled on Marcel's Mac), so ⌃⌥←/⌃⌥→ are hidden aliases that always work.
- **Fixed: tabs were top-aligned in the strip.** The GeometryReader was placing content at the top; the tabs are now vertically centered.
- Menu actions fall back to the frontmost window when the app is not active.
- Plain ⌃←/⌃→ "didn't work": in-app they work (verified with the new `debug.sh key <code> <mods>` command, which posts real key events). macOS was taking them for Spaces. With Marcel's OK, symbolic hotkeys 79/81 (⌃←/⌃→ "Move left/right a space") were disabled system-wide; ⌃⇧←/→ (80/82) still switch Spaces. The backup is at `.build/symbolichotkeys-backup.plist`; restore with `defaults import com.apple.symbolichotkeys <file>`, then log out and back in.

## 2026-09-24: Phases 0–2 built in one session
**State:** a working app. Build and launch it with `scripts/bundle.sh --open` (or `scripts/dev-run.sh` for an isolated dev instance).

Done
- **Core** (`SmartTerminalCore`): flat tab list + group ids (the Chrome model), with every operation behind invariant checks. 37 tests, including a 20-seed × 400-step random fuzz across 2 windows. `ShellTitle` parses `user@host:path` titles.
- **Tab system:** strip with colored group chips (click collapses, double-click edits), tinted and underlined group tabs, inline rename, group editor popover (name, 9 colors, new tab in group, ungroup, move to new window, close), context menus, drag-and-drop drop targets with insertion markers, "Move to New Window", tear-off.
- **Terminal:** SwiftTerm per tab (lazy, kept alive across tab switches and window moves), login shell, live cwd and foreground-command titles, bell and activity dots, close confirmation for running commands, ⌘+/⌘-/⌘0, ⌘K, ⌘F.
- **Terminal.app profile import:** font, colors, ANSI palette, translucency/blur and option-as-meta come from the Terminal.app default profile (Marcel's: "Clear Dark", FiraCode NF 15pt).
- **Persistence:** `~/Library/Application Support/SmartTerminal/layout.json`: windows and frames, groups (name, color, collapsed), tab order, custom names, cwd. Verified across relaunches.

Bugs found and fixed along the way
- `createGroup` on a tab already in a group: the new group was pruned as empty mid-move (caught by a unit test).
- Crash on Move Tab/Group to New Window: a Swift exclusivity violation from reading `layout` inside `mutate` (caught by the debug channel).
- Menu validation was never called (Swift 6 no longer infers `@objc`); fixed with an `NSMenuItemValidation` conformance.
- Quit could remove tabs from the saved layout via late shell-exit callbacks.

Dev tooling
- `scripts/debug.sh <cmd>` drives a dev instance (launched with `SMART_TERMINAL_DEBUG=1`) through a DistributedNotification channel: `snapshot`, `newTab`, `rename`, `group`, `collapse`, `select`, `type`, `dump`, `probe`, `moveTabToNewWindow`. Snapshots render in-process, because this environment has no Screen Recording permission. They don't capture blur, and popovers are separate windows so they don't appear either.

Needs a hands-on check (cannot be automated here: no Accessibility/Screen Recording)
- Drag and drop: reorder, into/out of a group, a whole group, across windows, tear-off to the desktop.
- Keyboard shortcuts inside a focused terminal (⌘T/⌘W/⌘1-9/⌃Tab/⌘⇧I/⌥⌘G).
- Group editor popover look; light mode; the translucent blur look.

Next
1. Fix whatever the hands-on test turns up.
2. App icon; a small Settings pane (font, profile choice: "Terminal.app default" vs built-in).
3. Candidates for later: session persistence (daemon/tmux), split panes, quick switcher (⌘P fuzzy search over tab and group names), which fits the "find what I'm doing" goal.

## 2026-09-24: Kickoff
- Researched prior art: no native terminal has Chrome-style tab groups (TabTerm borrows Chrome itself). Picked SwiftTerm as the engine; libghostty is the fallback.
- Interview decisions are recorded in `scope.md` (horizontal strip, SwiftTerm, layout-only persistence, multi-window).
