#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
identity_file="$HOME/Library/Application Support/SolarBar/Signing/identity"
identity="${SOLARBAR_SIGN_IDENTITY:-}"
if [[ -z "$identity" && -r "$identity_file" ]]; then
    identity=$(cat "$identity_file")
fi
if [[ -z "$identity" ]]; then
    cat >&2 <<'MSG'
SolarBar needs a stable signing identity so macOS can remember Bluetooth and Keychain approvals.
Set SOLARBAR_SIGN_IDENTITY to an installed Apple Development or Developer ID Application
identity. SolarBar does not install certificates or change trust settings. For an ad-hoc build,
explicitly set SOLARBAR_SIGN_IDENTITY=- (permissions may reset on every rebuild).
MSG
    exit 1
fi
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
