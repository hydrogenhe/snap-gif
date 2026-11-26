#!/bin/bash
set -euo pipefail

if [[ $# != 1 || ! -d "$1" ]]; then
    echo "Usage: $0 <directory containing both release ZIPs>" >&2
    exit 2
fi

release_dir="$(cd "$1" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

for arch in arm64 x86_64; do
    name="snap-gif-macOS-$arch"
    payload="$stage/$arch.noindex"
    mkdir "$payload"
    /usr/bin/ditto -x -k "$release_dir/$name.zip" "$payload"
    /usr/bin/codesign --verify --strict "$payload/snap-gif.app"
    /bin/ln -s /Applications "$payload/Applications"
    /usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO -volname "snap-gif ($arch)" \
        -srcfolder "$payload" "$stage/$name.dmg"
    /bin/mv "$stage/$name.dmg" "$release_dir/$name.dmg"
done
