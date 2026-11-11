#!/usr/bin/env bash
#
# Build and wrap the SwiftPM executable into SmartTerminal.app.
#
# Usage:
#   scripts/bundle.sh             # debug build  -> ./SmartTerminal.app
#   scripts/bundle.sh --release   # release build
#   scripts/bundle.sh --open      # also launch it
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
OPEN=0
for a in "$@"; do
    case "$a" in
        --release) CONFIG=release ;;
        --open) OPEN=1 ;;
    esac
done

if [[ -n "${SMART_TERMINAL_BINARY:-}" ]]; then
    BIN="$SMART_TERMINAL_BINARY"   # prebuilt (release.sh passes a universal binary)
    MCP_BIN="${SMART_TERMINAL_MCP_BINARY:?release.sh passes smart-terminal-mcp too}"
else
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/SmartTerminal"
    MCP_BIN="$(swift build -c "$CONFIG" --show-bin-path)/SmartTerminalMCP"
fi
VERSION="$(cat VERSION)"
BUILD="$(date -u +%Y%m%d%H%M)"   # monotonic build number (CFBundleVersion)
APP="${SMART_TERMINAL_APP:-SmartTerminal.app}"   # test-run.sh builds elsewhere so it never rewrites a running dev bundle
# Dev, test and demo builds get their own bundle id and name. macOS keeps one privacy
# grant (Screen Recording, Automation, notifications) per bundle id, tied to the
# signature it saw: with the release's id, an Apple Development build took over the
# installed app's grant and the notarized app was refused, with no way to add it.
# Separate ids also keep their settings out of the installed app's.
if [[ $CONFIG == release ]]; then
    BUNDLE_ID=com.pluginslab.smartterminal; APP_NAME="Smart Terminal"
else
    BUNDLE_ID=com.pluginslab.smartterminal.dev; APP_NAME="Smart Terminal Dev"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SmartTerminal"
# The MCP server Claude Code starts in a tab: claude mcp add -s user smart-terminal -- <app>/Contents/MacOS/smart-terminal-mcp
cp "$MCP_BIN" "$APP/Contents/MacOS/smart-terminal-mcp"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SmartTerminal</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Pluginslab. MIT License.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>Smart Terminal reads your open Terminal.app tabs so it can import them.</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.pluginslab.smartterminal.tab</string>
            <key>UTTypeDescription</key><string>Smart Terminal Tab</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.pluginslab.smartterminal.group</string>
            <key>UTTypeDescription</key><string>Smart Terminal Tab Group</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# A stable signing identity keeps macOS privacy grants (Automation, notifications)
# across rebuilds; an ad-hoc signature changes every build and re-prompts.
IDENTITY="${SMART_TERMINAL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
# Inside out: the MCP server, then the app.
sign_all() {
    local id="$1" hardened="$2"
    local base=(--force --sign "$id")
    [[ $hardened == 1 ]] && base+=(--options runtime --timestamp)
    codesign "${base[@]}" --identifier "$BUNDLE_ID.mcp" "$APP/Contents/MacOS/smart-terminal-mcp" || return 1
    local app_flags=("${base[@]}")
    [[ $hardened == 1 ]] && app_flags+=(--entitlements SmartTerminal.entitlements)
    codesign "${app_flags[@]}" "$APP"
}
HARDENED="${SMART_TERMINAL_HARDENED:-0}"   # distribution: hardened runtime + timestamp (notarization)
if [[ -n "$IDENTITY" ]] && sign_all "$IDENTITY" "$HARDENED"; then
    echo "==> signed with: $IDENTITY"
else
    sign_all - 0 >/dev/null 2>&1
    echo "==> signed ad-hoc"
fi
echo "==> $APP ($CONFIG, v$VERSION)"
[[ $OPEN == 1 ]] && open "$APP"
exit 0
