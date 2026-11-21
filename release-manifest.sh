#!/bin/bash
set -euo pipefail
if [[ $# != 1 ]]; then
    echo "Usage: $0 <directory containing both release ZIPs>" >&2
    exit 2
fi
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$(dirname "$0")/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
arm_hash=$(/usr/bin/shasum -a 256 "$1/snap-gif-macOS-arm64.zip" | /usr/bin/cut -d' ' -f1)
intel_hash=$(/usr/bin/shasum -a 256 "$1/snap-gif-macOS-x86_64.zip" | /usr/bin/cut -d' ' -f1)
printf '{"tag_name":"v%s","assets":[{"name":"snap-gif-macOS-arm64.zip","digest":"sha256:%s"},{"name":"snap-gif-macOS-x86_64.zip","digest":"sha256:%s"}]}\n' \
    "$version" "$arm_hash" "$intel_hash" > "$1/snap-gif-update.json"
