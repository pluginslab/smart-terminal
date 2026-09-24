#!/usr/bin/env bash
#
# Builds a notarized, stapled, universal Smart Terminal DMG in dist/.
#
#   scripts/release.sh
#
# Prereqs (one-time): a "Developer ID Application" certificate in the keychain and a
# notarytool keychain profile (xcrun notarytool store-credentials <profile>).
# Override with SMART_TERMINAL_SIGN_IDENTITY / NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
IDENTITY="${SMART_TERMINAL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
PROFILE="${NOTARY_PROFILE:-fujifilm-notary}"
DIST="dist"
APP="SmartTerminal.app"
DMG="$DIST/SmartTerminal-$VERSION.dmg"

[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found" >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no ## [$VERSION] entry" >&2; exit 1; }

echo "==> tests"
swift test 2>&1 | grep -E "Test run with|error" | tail -2

echo "==> universal release build"
swift build -c release --triple arm64-apple-macosx26.0 --scratch-path .build/rel-arm64 >/dev/null
swift build -c release --triple x86_64-apple-macosx26.0 --scratch-path .build/rel-x86_64 >/dev/null
lipo -create .build/rel-arm64/release/SmartTerminal .build/rel-x86_64/release/SmartTerminal -output .build/SmartTerminal-universal
lipo -info .build/SmartTerminal-universal

echo "==> bundle + sign ($IDENTITY)"
SMART_TERMINAL_BINARY=.build/SmartTerminal-universal SMART_TERMINAL_SIGN_IDENTITY="$IDENTITY" SMART_TERMINAL_HARDENED=1 \
    scripts/bundle.sh --release
codesign --verify --strict --deep --verbose=1 "$APP"

echo "==> notarize app"
mkdir -p "$DIST"
ZIP="$DIST/SmartTerminal-$VERSION.zip"
rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Smart Terminal $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
rm -f "$ZIP"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> $DMG ready"
