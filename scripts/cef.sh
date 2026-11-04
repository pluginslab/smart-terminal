#!/usr/bin/env bash
# The pinned Chromium (CEF) build. The pin is CefSwift's CEF_VERSION.json (vendored),
# so the C headers we compile against and the binary always match.
#   scripts/cef.sh framework   # path to the framework, downloading it on first use
#   scripts/cef.sh universal   # both architectures in one framework (release.sh)
#   scripts/cef.sh version
set -euo pipefail
cd "$(dirname "$0")/.."
manifest() {
    echo Vendor/CefSwift/CEF_VERSION.json
}
version() { /usr/bin/plutil -extract cef raw -o - "$(manifest)"; }
case "${1:-framework}" in
    version) version ;;
    framework)
        arch="${CEF_PLATFORM:-macos$( [[ $(uname -m) == arm64 ]] && echo arm64 || echo x64 )}"
        fw=".cef/dist/$(version)_${arch}_minimal/Release/Chromium Embedded Framework.framework"
        if [[ ! -d $fw ]]; then
            swift package --allow-writing-to-package-directory --allow-network-connections all \
                cef download --platform "$arch" >&2
        fi
        echo "$PWD/$fw" ;;
    universal)
        # The two builds differ only in their binaries and V8's snapshot file (named per
        # architecture): start from arm64, merge each binary, add the Intel snapshot.
        arm="$(CEF_PLATFORM=macosarm64 "$0" framework)"
        x64="$(CEF_PLATFORM=macosx64 "$0" framework)"
        out=".cef/universal-$(version)/Chromium Embedded Framework.framework"
        if [[ ! -d $out ]]; then
            rm -rf "$(dirname "$out")"
            mkdir -p "$(dirname "$out")"
            cp -R "$arm" "$out"
            for bin in "Chromium Embedded Framework" Libraries/libcef_sandbox.dylib \
                       Libraries/libvk_swiftshader.dylib Libraries/libvulkan.dylib; do
                lipo -create "$arm/Versions/A/$bin" "$x64/Versions/A/$bin" -output "$out/Versions/A/$bin"
            done
            cp "$x64/Versions/A/Resources/v8_context_snapshot.x86_64.bin" "$out/Versions/A/Resources/"
        fi
        echo "$PWD/$out" ;;
    *) echo "usage: scripts/cef.sh framework|universal|version" >&2; exit 2 ;;
esac
