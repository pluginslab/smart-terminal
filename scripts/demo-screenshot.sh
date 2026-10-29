#!/usr/bin/env bash
#
# Takes the README screenshot, assets/screenshot.png, from the app itself: the
# columns layout with two groups, sessions showing their git branch and diff, and a
# Claude Code tab at work with subagents running, its status bar under the terminal.
#
#   scripts/demo-screenshot.sh
#   DEMO_BROWSER=https://… DEMO_OUT=assets/screenshot-browser.png scripts/demo-screenshot.sh
#       the same scene with that page open in the Claude tab's browser, in a wider window
#
# Everything shown is invented: the three demo folders become throwaway git repos for
# the length of the run (removed afterwards), a demo copy of the app runs with HOME=demo/home (a
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

# Shared preferences: the columns layout, with the clipboard sidebar closed.
defaults write com.pluginslab.smartterminal sidebarOpen -bool false
defaults write com.pluginslab.smartterminal tabLayout -string sidebar

# Invented git state per folder. Own identity, no signing, no hooks: your git config
# must not leak into the picture or prompt for anything.
CODE="$REPO/demo/home/code"
g() { git -C "$1" -c user.name=Demo -c user.email=demo@example.com -c commit.gpgsign=false \
        -c core.hooksPath=/dev/null -c init.defaultBranch=main "${@:2}" >/dev/null 2>&1; }
demo_repo() { # folder, files…
    local dir="$CODE/$1"; shift
    rm -rf "$dir/.git"; g "$dir" init
    for f in "$@"; do mkdir -p "$(dirname "$dir/$f")"; seq 1 40 | sed "s|^|// $f line |" > "$dir/$f"; done
    g "$dir" add -A; g "$dir" commit -m "Initial import"
    git clone -q --bare "$dir" "$WORK/remote-$(basename "$dir").git"
    g "$dir" remote add origin "$WORK/remote-$(basename "$dir").git"; g "$dir" fetch origin
}
DEMO_FILES=()
cleanup_repos() {
    for d in acme-api acme-web infra; do rm -rf "$CODE/$d/.git"; done
    for f in "${DEMO_FILES[@]}"; do rm -f "$CODE/$f"; done
    for d in acme-api acme-web infra; do find "$CODE/$d" -mindepth 1 -type d -empty -delete 2>/dev/null || true; done
}

"$HELPER" save "$WORK/clipboard.plist"
restore() {
    cleanup_repos
    "$HELPER" restore "$WORK/clipboard.plist" 2>/dev/null || true
    pkill -f "^$APP/Contents/MacOS/SmartTerminal" 2>/dev/null || true
}
trap restore EXIT

echo "==> demo repos"
DEMO_FILES=(acme-api/src/webhooks.ts acme-api/src/retry.ts acme-api/README.md
            acme-web/src/app.tsx acme-web/package.json infra/main.tf infra/variables.tf infra/notes.md)
demo_repo acme-api src/webhooks.ts src/retry.ts README.md
g "$CODE/acme-api" checkout -b stripe-retries; g "$CODE/acme-api" push -u origin stripe-retries
for i in 1 2; do echo "// retry pass $i" >> "$CODE/acme-api/src/retry.ts"; g "$CODE/acme-api" commit -am "Retry pass $i"; done
sed -i '' '1,6d' "$CODE/acme-api/src/webhooks.ts"
seq 1 38 | sed 's|^|// backoff |' >> "$CODE/acme-api/src/webhooks.ts"        # ↑2, +38 −6
demo_repo acme-web src/app.tsx package.json; g "$CODE/acme-web" push -u origin main   # clean
demo_repo infra main.tf variables.tf; g "$CODE/infra" push -u origin main
g "$CODE/infra" fetch origin; echo '# region' >> "$CODE/infra/variables.tf"
printf 'a\nb\nc\n' >> "$CODE/infra/main.tf"; sed -i '' '2d' "$CODE/infra/main.tf"
echo "todo" > "$CODE/infra/notes.md"                                             # +4 −1 ?1

echo "==> launch demo instance"
mkdir -p "$WORK/claude" "$WORK/support"
open -n --env HOME="$REPO/demo/home" --env CLAUDE_CONFIG_DIR="$WORK/claude" \
    --env SMART_TERMINAL_SUPPORT_DIR="$WORK/support" --env SMART_TERMINAL_DEBUG=1 \
    --env SMART_TERMINAL_DEBUG_ID=$CHANNEL "$APP"
sleep 3
PID="$(pgrep -f "^$APP/Contents/MacOS/SmartTerminal")"

st() { "$HELPER" post $CHANNEL "$@"; }
OUT="${DEMO_OUT:-assets/screenshot.png}"
if [[ -n "${DEMO_BROWSER:-}" ]]; then st resize 1800 900; else st resize 1480 860; fi
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
sleep 0.4; st select 1
sleep 0.4; st type 'claude\n'
sleep 1.0
# As if Claude had run `open <url>` in this tab: the page loads in its browser pane.
[[ -n "${DEMO_BROWSER:-}" ]] && st openURL "$DEMO_BROWSER"
# The fake launches three subagents ~5 s in; ~13 s in, one is done and two still run.
sleep 10.8
st activate
# macOS won't let a background app bring itself forward while you're in another one;
# System Events can, so the window is captured as the active one (coloured buttons).
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1 || true
sleep 0.8

# DEMO_PREVIEW=<png>: the app's own snapshot instead, which needs no Screen Recording
# permission but can't draw glass or the sidebar material. For checking the scene only.
if [[ -n "${DEMO_PREVIEW:-}" ]]; then
    st snapshot "$DEMO_PREVIEW"; sleep 2; ls -la "$DEMO_PREVIEW"; exit 0
fi

echo "==> capture"
WID="$("$HELPER" windowid "$PID")"
mkdir -p assets
screencapture -x -l"$WID" "$OUT"   # with the window's shadow, on transparency
sips -g pixelWidth -g pixelHeight "$OUT" | tail -2
ls -la "$OUT"
