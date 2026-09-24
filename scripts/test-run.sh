#!/usr/bin/env bash
# Launches a separate, throwaway TEST instance (copy of the bundle, own layout dir,
# debug channel "test") so automated checks never touch a dev instance in use.
#   scripts/test-run.sh            # rebuild + fresh test instance
#   scripts/test-run.sh --keep     # relaunch, keeping the test layout (restart/restore tests)
#   SMART_TERMINAL_DEBUG_ID=test scripts/debug.sh snapshot /tmp/x.png
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/.build/SmartTerminal-test.app"
SUPPORT="$PWD/.build/test-support"
pkill -f "^$APP/Contents/MacOS/SmartTerminal" 2>/dev/null || true
# Build straight into the test bundle: never rebuild SmartTerminal.app, which a dev
# instance may be running from.
[[ "${1:-}" == "--keep" ]] || rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
SMART_TERMINAL_APP="$APP" scripts/bundle.sh >/dev/null
open -n --env SMART_TERMINAL_SUPPORT_DIR="$SUPPORT" --env SMART_TERMINAL_DEBUG=1 --env SMART_TERMINAL_DEBUG_ID=test --env SMART_TERMINAL_LOG_OUTPUT="${SMART_TERMINAL_LOG_OUTPUT:-0}" "$APP"
echo "launched test instance (support dir: $SUPPORT)"
