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
else
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/SmartTerminal"
fi
VERSION="$(cat VERSION)"
BUILD="$(date -u +%Y%m%d%H%M)"   # monotonic build number (CFBundleVersion)
APP="SmartTerminal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SmartTerminal"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SmartTerminal</string>
    <key>CFBundleIdentifier</key><string>com.pluginslab.smartterminal</string>
    <key>CFBundleName</key><string>Smart Terminal</string>
    <key>CFBundleDisplayName</key><string>Smart Terminal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Pluginslab. MIT License.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
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
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "${SMART_TERMINAL_HARDENED:-0}" == 1 ]]; then
    # Distribution: hardened runtime + secure timestamp + entitlements (required for notarization).
    SIGN_FLAGS+=(--options runtime --timestamp --entitlements SmartTerminal.entitlements)
fi
if [[ -n "$IDENTITY" ]] && codesign "${SIGN_FLAGS[@]}" "$APP"; then
    echo "==> signed with: $IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "==> signed ad-hoc"
fi
echo "==> $APP ($CONFIG, v$VERSION)"
[[ $OPEN == 1 ]] && open "$APP"
exit 0
