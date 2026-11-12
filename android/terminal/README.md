# terminal (vendored)

Termux's `terminal-emulator` and `terminal-view` libraries, Apache License 2.0, copied from
termux-app v0.118.3 (commit in `VENDORED`). Vendored rather than pulled from JitPack: JitPack
builds from GitHub tags, which can move (see docs/android-plan.md, the Citadel lesson).

Our changes, and only these:
- `TerminalSession` no longer starts a local process through JNI (`JNI.java` and the C code are
  gone). Bytes come from and go to a `TerminalSession.Transport`: an SSH channel in this app.
- `TerminalView`: with mouse tracking on (tmux `mouse on`), one wheel step per 2.5 rows of finger
  travel and a fifth of the fling range, since tmux scrolls 5 lines per step.
