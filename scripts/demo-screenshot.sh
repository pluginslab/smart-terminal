#!/usr/bin/env bash
#
# Takes the README screenshot, assets/screenshot.png, from the app itself:
# tab groups (one collapsed), a Claude Code tab at work, and the sidebar's Claude pane
# with subagents running and done.
#
#   scripts/demo-screenshot.sh
#
# Everything shown is invented: a demo copy of the app runs with HOME=demo/home (a
# plain zsh prompt, no personal config) and CLAUDE_CONFIG_DIR in a temp folder, and
# `claude` is demo/fake-claude.swift (built to .build/demo-bin/claude), which writes
# Claude Code's files without calling anything. Your clipboard is saved first and
# restored afterwards. The shot is of the window alone: no pointer, and other windows
# don't matter; the demo window is brought to the front so it's drawn as active.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

APP="$REPO/.build/SmartTerminal-demo.app"
WORK="$(mktemp -d -t smart-terminal-demo)"
HELPER="$REPO/.build/demo-helper"
CHANNEL=demo

echo "==> build"
swiftc -O scripts/demo-helper.swift -o "$HELPER" 2>/dev/null
mkdir -p .build/demo-bin && swiftc -O demo/fake-claude.swift -o .build/demo-bin/claude
pkill -f "^$APP/Contents/MacOS/SmartTerminal" 2>/dev/null || true
SMART_TERMINAL_APP="$APP" scripts/bundle.sh >/dev/null

# Shared preferences: start with the sidebar closed, on the Claude pane.
defaults write com.pluginslab.smartterminal sidebarOpen -bool false
defaults write com.pluginslab.smartterminal sidebarPane -string claude
defaults write com.pluginslab.smartterminal sidebarWidth -float 310

"$HELPER" save "$WORK/clipboard.plist"
restore() {
    "$HELPER" restore "$WORK/clipboard.plist" 2>/dev/null || true
    pkill -f "^$APP/Contents/MacOS/SmartTerminal" 2>/dev/null || true
}
trap restore EXIT

echo "==> launch demo instance"
mkdir -p "$WORK/claude" "$WORK/support"
open -n --env HOME="$REPO/demo/home" --env CLAUDE_CONFIG_DIR="$WORK/claude" \
    --env SMART_TERMINAL_SUPPORT_DIR="$WORK/support" --env SMART_TERMINAL_DEBUG=1 \
    --env SMART_TERMINAL_DEBUG_ID=$CHANNEL "$APP"
sleep 3
PID="$(pgrep -f "^$APP/Contents/MacOS/SmartTerminal")"

st() { "$HELPER" post $CHANNEL "$@"; }
st resize 1180 700
st activate
sleep 1.5
st type $'\x15clear\\n'   # ^U first: drop anything that reached the prompt at startup
sleep 1
# Preflight: the demo shell's `claude` must be the fake, never the real Claude Code.
st type "whence -w claude > '$WORK/which' 2>&1\\n"
sleep 1
if ! grep -q "claude: function" "$WORK/which" 2>/dev/null; then
    echo "demo shell's claude isn't the fake ($(cat "$WORK/which" 2>/dev/null)); aborting" >&2
    exit 1
fi
st type $'\x15clear\\n'
sleep 0.8

echo "==> scene"
# A new tab's shell starts when the tab is shown: give it a moment before typing.
st type 'cd code/acme-api\n'
sleep 0.6; st group api blue
sleep 0.5; st newTabInGroup
sleep 1.0; st newTab end
sleep 1.0; st type 'cd ~/code/acme-web\n'
sleep 0.6; st group web green
sleep 0.5; st newTab end
sleep 1.0; st type 'cd ~/code/infra\n'
sleep 0.6; st toggleGroup web     # collapsed: shows as a chip with its tab count
sleep 0.4; st select 1
sleep 0.4; st type 'claude\n'
sleep 1.0; st sidebar             # opens on the Claude pane
# The fake launches three subagents ~5 s in; ~13 s in, one is done and two still run.
sleep 10.8
st activate
# macOS won't let a background app bring itself forward while you're in another one;
# System Events can, so the window is captured as the active one (coloured buttons).
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1 || true
sleep 0.8

echo "==> capture"
WID="$("$HELPER" windowid "$PID")"
mkdir -p assets
screencapture -x -l"$WID" assets/screenshot.png   # with the window's shadow, on transparency
sips -g pixelWidth -g pixelHeight assets/screenshot.png | tail -2
ls -la assets/screenshot.png
