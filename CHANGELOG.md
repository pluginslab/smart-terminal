# Changelog

## [Unreleased]
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
