#!/usr/bin/env bash
# The pinned Chromium (CEF) build. The pin is CefSwift's CEF_VERSION.json, in the
# package checkout, so the C headers we compile against and the binary always match.
#   scripts/cef.sh framework   # path to the framework, downloading it on first use
#   scripts/cef.sh version
set -euo pipefail
cd "$(dirname "$0")/.."
manifest() {
    local m=.build/checkouts/CefSwift/CEF_VERSION.json
    [[ -f $m ]] || swift package resolve >/dev/null
    echo "$m"
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
    *) echo "usage: scripts/cef.sh framework|version" >&2; exit 2 ;;
esac
