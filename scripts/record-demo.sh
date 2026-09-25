#!/usr/bin/env bash
#
# Records the README demo: assets/demo.mp4 and assets/demo.gif.
#
#   scripts/record-demo.sh            build, play the scenes, record, encode
#   scripts/record-demo.sh --dry-run  play the scenes without recording
#
# Everything shown is invented: a demo copy of the app runs with HOME=demo/home (a
# plain zsh prompt, no personal config) and CLAUDE_CONFIG_DIR in a temp folder, and
# `claude` is demo/fake-claude.swift (built to .build/demo-bin/claude), which writes Claude Code's files without calling
# anything. Your clipboard is saved first and restored afterwards.
#
# While it records (about 45 s), leave the demo window in front and don't copy anything.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

APP="$REPO/.build/SmartTerminal-demo.app"
WORK="$(mktemp -d -t smart-terminal-demo)"
HELPER="$REPO/.build/demo-helper"
CHANNEL=demo
DURATION=46

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
BOUNDS="$("$HELPER" bounds "$PID")"
echo "    window: $BOUNDS"

T0=0
at() { # at <seconds> <debug command...>: waits until that point in the scene, then sends it
    local target="$1"; shift
    local now; now="$(python3 -c "import time; print(time.time())")"
    local wait; wait="$(python3 -c "print(max(0, $T0 + $target - $now))")"
    sleep "$wait"
    [[ $# -gt 0 ]] && st "$@"
    return 0
}

if [[ $DRY -eq 0 ]]; then
    echo "==> recording ${DURATION}s: leave the window alone"
    screencapture -v -V $DURATION -R"$BOUNDS" "$WORK/demo.mov" &
    REC=$!
    sleep 1.2 # the recorder takes a moment to start
fi
T0="$(python3 -c "import time; print(time.time())")"

# Tabs and groups
at 0.5  typeSlow 'cd code/acme-api\n'
at 2.2  group api blue
at 3.2  newTabInGroup
at 4.0  typeSlow 'ls\n'
at 5.2  newTab end
at 5.8  typeSlow 'cd ~/code/acme-web\n'
at 7.4  group web green
at 8.4  newTab end
at 9.0  typeSlow 'cd ~/code/infra\n'
at 10.8 toggleGroup web
at 12.4 toggleGroup web
# Claude in the first tab, with the sidebar's Claude pane
at 13.6 select 1
at 14.2 typeSlow 'claude\n'
at 16.4 sidebar
at 24.0 subagentPopover 1
at 28.2 subagentPopover
# Clipboard: a pbcopy and a copied image flash in
at 35.0 pane clipboard
at 35.6 select 4
at 36.2 typeSlow 'echo "https://github.com/acme/api/pull/482" | pbcopy\n'
at 40.0
"$HELPER" image "$REPO/Resources/AppIcon.png"
at 42.0 typeSlow 'printf "deploy acme-api@4.12.0" | pbcopy\n'
at $DURATION

if [[ $DRY -eq 1 ]]; then echo "==> dry run done"; exit 0; fi
wait $REC || true

echo "==> encode"
mkdir -p assets
ffmpeg -loglevel error -y -i "$WORK/demo.mov" -vf "fps=30,scale=1440:-2:flags=lanczos" \
    -c:v libx264 -crf 23 -preset slow -pix_fmt yuv420p -movflags +faststart -an assets/demo.mp4
ffmpeg -loglevel error -y -i "$WORK/demo.mov" -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    assets/demo.gif
ls -la assets/demo.mp4 assets/demo.gif
echo "==> done (work files in $WORK)"
