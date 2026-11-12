#!/usr/bin/env bash
# Launches (in the background, never taking focus from what you type in) a separate, throwaway TEST instance (copy of the bundle, own layout dir,
# debug channel "test") so automated checks never touch a dev instance in use.
#   scripts/test-run.sh            # rebuild + fresh test instance
#   scripts/test-run.sh --keep     # relaunch, keeping the test layout (restart/restore tests)
#   SMART_TERMINAL_DEBUG_ID=test scripts/debug.sh snapshot /tmp/x.png
set -euo pipefail
cd "$(dirname "$0")/.."
# Run from a Smart Terminal tab, the instance would inherit that tab's shell setup
# (its zsh shim, your dotfiles' folder) and its tab and agent gate.
unset ZDOTDIR SMART_TERMINAL_USER_ZDOTDIR SMART_TERMINAL_TAB SMART_TERMINAL_GATE
APP="$PWD/.build/SmartTerminal-test.app"
SUPPORT="$PWD/.build/test-support"
pkill -f "^$APP/Contents/MacOS/SmartTerminal" 2>/dev/null || true
# Build straight into the test bundle: never rebuild SmartTerminal.app, which a dev
# instance may be running from.
[[ "${1:-}" == "--keep" ]] || rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
SMART_TERMINAL_APP="$APP" scripts/bundle.sh >/dev/null
open -n -g --env SMART_TERMINAL_SUPPORT_DIR="$SUPPORT" --env SMART_TERMINAL_DEBUG=1 --env SMART_TERMINAL_DEBUG_ID=test --env SMART_TERMINAL_TEST_POPUPS="${SMART_TERMINAL_TEST_POPUPS:-0}" --env SMART_TERMINAL_LOG_OUTPUT="${SMART_TERMINAL_LOG_OUTPUT:-0}" --env SMART_TERMINAL_LOCK="${SMART_TERMINAL_LOCK:-0}" --env SMART_TERMINAL_LOCK_NOKEY="${SMART_TERMINAL_LOCK_NOKEY:-0}" "$APP"
echo "launched test instance (support dir: $SUPPORT)"
