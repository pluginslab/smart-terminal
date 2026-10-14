#!/usr/bin/env bash
# Renders Resources/AppIcon.svg to Resources/AppIcon-art.png (1024², with headless
# Chrome, which draws SVG filters faithfully), then AppIcon.png and AppIcon.icns.
#   scripts/render-icon.sh [out.png]    # with an argument: only render, to out.png
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT="${1:-Resources/AppIcon-art.png}"
TMP="$(mktemp -d)"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=1024,1024 \
    --screenshot="$TMP/icon.png" "file://$PWD/Resources/AppIcon.svg" >/dev/null 2>&1
mv "$TMP/icon.png" "$OUT"; rm -rf "$TMP"
echo "wrote $OUT"
[[ $# -gt 0 ]] || swift scripts/compose-icon.swift Resources/AppIcon-art.png Resources/AppIcon.png --icns
