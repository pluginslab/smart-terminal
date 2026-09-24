#!/usr/bin/env bash
# Rebuilds and (re)launches the dev instance: own layout dir, debug channel "dev".
# Only the dev instance is restarted; a test instance or the real app is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
SUPPORT="${SMART_TERMINAL_SUPPORT_DIR:-$PWD/.build/dev-support}"
mkdir -p "$SUPPORT"
pkill -f "^$PWD/SmartTerminal.app/Contents/MacOS/SmartTerminal" 2>/dev/null || true
scripts/bundle.sh >/dev/null
open -n --env SMART_TERMINAL_SUPPORT_DIR="$SUPPORT" --env SMART_TERMINAL_DEBUG=1 --env SMART_TERMINAL_DEBUG_ID=dev SmartTerminal.app
echo "launched dev instance (support dir: $SUPPORT)"
