#!/usr/bin/env bash
# Sends a command to a SmartTerminal launched with SMART_TERMINAL_DEBUG=1.
# Targets the instance named by $SMART_TERMINAL_DEBUG_ID (default "dev"; test-run.sh uses "test").
# Usage: scripts/debug.sh <command> [args...]   (see Sources/SmartTerminal/App/DebugChannel.swift)
set -euo pipefail
payload="$(printf '%s\x1f' "$@")"
payload="${payload%$'\x1f'}"
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"com.pluginslab.smartterminal.debug.${SMART_TERMINAL_DEBUG_ID:-dev}\"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)" "$payload"
