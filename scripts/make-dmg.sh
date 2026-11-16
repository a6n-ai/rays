#!/bin/bash
# Builds Rays-<version>.dmg: Rays.app next to an Applications shortcut, so users drag to install.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw bin/Rays.app/Contents/Info.plist)}"
OUT="Rays-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto bin/Rays.app "$STAGE/Rays.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Rays" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "$OUT"
