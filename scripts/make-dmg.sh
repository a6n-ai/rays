#!/bin/bash
# Builds Rays-<version>.dmg: Rays.app beside an Applications shortcut on a background that says to drag.
# dmgbuild writes the window layout itself, so this works without Finder (CI included).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw bin/Rays.app/Contents/Info.plist)}"
OUT="Rays-${VERSION}.dmg"
rm -f "$OUT"
uvx --quiet --from "dmgbuild==1.6.5" dmgbuild -s scripts/dmg/settings.py \
  -D app=bin/Rays.app -D background=scripts/dmg/background.tiff "Rays" "$OUT" >/dev/null
echo "$OUT"
