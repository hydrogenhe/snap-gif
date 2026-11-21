#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="${1:-$PWD/build/snap-gif.app}"
mkdir -p "$app/Contents/MacOS"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
arch="$(uname -m)"
xcrun swiftc -module-cache-path "$PWD/build/module-cache" -swift-version 5 -O -sdk "$sdk" -target "$arch-apple-macosx14.0" \
    Sources/*.swift -o "$app/Contents/MacOS/snap-gif"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier io.github.hydrogenhe.snap-gif "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
