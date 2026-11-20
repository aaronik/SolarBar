#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# A local build needs no certificate. Use an explicitly supplied identity to
# preserve system approvals across builds; an invalid identity fails below.
identity="${SOLARBAR_SIGN_IDENTITY:--}"
if [[ "$identity" == - ]]; then
    echo 'Warning: ad-hoc signing does not preserve approvals across rebuilds.' >&2
fi
mkdir -p build
stage=$(mktemp -d "$PWD/build/.staging.XXXXXX")
app=build/SolarBar.app
trap 'if [[ -d "$stage/previous.app" && ! -e "$app" ]]; then mv "$stage/previous.app" "$app"; fi; rm -rf "$stage"' EXIT
candidate="$stage/SolarBar.app"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" -O -o "$candidate/Contents/MacOS/SolarBar" Sources/SolarBar/*.swift
cp Info.plist "$candidate/Contents/Info.plist"
cp Resources/SolarBar.icns "$candidate/Contents/Resources/"
codesign --force --sign "$identity" --timestamp=none "$candidate"
codesign --verify --strict "$candidate"
if [[ -e "$app" ]]; then mv "$app" "$stage/previous.app"; fi
mv "$candidate" "$app"
printf 'Built %s/%s\n' "$PWD" "$app"
