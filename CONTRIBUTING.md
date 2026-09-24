# Contributing to Smart Terminal

Thanks for taking a look. This file exists to save you the archaeology.

## Getting set up

```bash
git clone https://github.com/pluginslab/smart-terminal.git
cd smart-terminal
swift test
scripts/bundle.sh --open
```

You need **macOS 26** and **Xcode 26** (Swift 6.2). You don't need Claude Code
installed to work on the app, only to see the Claude features in action.

## Instances: don't test in the terminal you are using

Smart Terminal is a terminal, so it's easy to kill your own shells while testing it.
There are three kinds of instance:

| | Layout file | Debug channel | Use for |
| --- | --- | --- | --- |
| `scripts/bundle.sh --open` | your real one | no | using it |
| `scripts/dev-run.sh` | `.build/dev-support/` | `dev` | trying a change by hand |
| `scripts/test-run.sh` | `.build/test-support/` (wiped each run, `--keep` to keep it) | `test` | automated checks |

Each script restarts only its own instance.

In DEBUG builds with `SMART_TERMINAL_DEBUG=1`, `scripts/debug.sh <command>` drives an
instance: `snapshot`, `newTab`, `rename`, `group`, `collapse`, `select`, `type`,
`key`, `resize`, `dump`, `state`, `probe`, `wintitle`, `resume`, `importScan` (a dry
run) and more. Set `SMART_TERMINAL_DEBUG_ID=test` to target the test instance. The
list is in `Sources/SmartTerminal/App/DebugChannel.swift`. Snapshots render inside
the app, so they need no Screen Recording permission.

## How the code fits together

```
Sources/SmartTerminalCore/     no UI, fully unit-tested
  Model.swift                  TerminalTab, TabGroup, GroupColor, DropTarget, StripItem
  WindowLayout.swift           one window: every tab/group operation + invariants
  AppLayout.swift              all windows, cross-window moves, detach
  LayoutStore.swift            JSON persistence
  ShellTitle.swift             user@host:path title parsing
  ClaudeCode.swift             Claude titles, session files, transcripts, resume command
  TerminalImport.swift         import planning (group by folder)
Sources/SmartTerminal/
  App/                         AppDelegate, menus, windows, notifications, debug channel
  Model/AppModel.swift         the observable store; every mutation goes through it
  Terminal/                    SwiftTerm sessions, process inspection, Claude watcher,
                               Terminal.app profile + tab import
  Views/                       tab strip, tabs, group chips, sheets
Tests/SmartTerminalCoreTests/
```

Design constraints worth knowing before you change things:

1. **Logic goes in Core.** If a behaviour can be expressed without AppKit (where a
   drop lands, what a title means, how a resume command is built), put it in
   `SmartTerminalCore` and test it there. The app layer should be plumbing.
2. **Tabs of a group stay contiguous.** `WindowLayout` enforces it after every
   operation, and `violations()` plus the fuzz test check it. Keep both passing.
3. **Terminal views outlive SwiftUI.** `SessionRegistry` owns each tab's SwiftTerm
   view, and `TerminalContainer` only re-parents it. Never put a terminal view inside
   a SwiftUI `if`/`else`: SwiftUI would destroy the shell.
4. **Never read the middle of a transcript.** They reach tens of megabytes. Read
   backwards from the end, then tail.
5. **Don't read `layout` inside `mutate {}`.** Swift's exclusivity checks will crash
   the app. Read what you need first, then mutate.

## Tests

```bash
swift test
```

If you add a tab or group operation, add a unit test for it and make sure the
invariant fuzz test still passes. Test data must be invented: no real host names,
folders or session names.

## Screenshots

`assets/screenshot.{svg,png}` are generated from invented demo data:

```bash
python3 scripts/mock-screenshot.py
```

It writes the SVG and rasterises it with headless Chrome at 2×. Chrome honours the
SVG's declared size, whereas `qlmanage` pads and clips. If the UI changes visibly,
update the mock in the same PR.

## Style

- Swift 6.2 with strict concurrency. The UI is `@MainActor`.
- 4 spaces and ~120 columns. `.editorconfig` covers the basics, and there is
  deliberately no formatter to argue with.
- Comment the *why*, not the *what*.

## Pull requests

- One change per PR.
- Add or update tests.
- Add a line to `CHANGELOG.md` under `## [Unreleased]`. Maintainers pick the version
  at release time.
- Say what you tested, and on which macOS version.

## Releases (maintainers)

Bump `VERSION`, move the Unreleased notes under `## [X.Y.Z]`, then run
`scripts/release.sh`. It builds a universal binary, signs it with a Developer ID
under the hardened runtime, notarizes and staples the app and the DMG, and checks
both with Gatekeeper. It refuses to run without a changelog entry for the version.
