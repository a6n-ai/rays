#!/usr/bin/env bash
# Signs macos/Resources/Shortcuts/*.shortcut into build/shortcuts/ so Shortcuts will import them.
# `shortcuts sign` needs an iCloud sign-in; CI runners have none, so release builds only get signed
# files when built on a Mac signed into iCloud, or when signed files are committed under
# macos/Resources/Shortcuts/signed/ (bundle-app.sh prefers those). Never fails: unsigned means no ready-made shortcuts.
set -uo pipefail
cd "$(dirname "$0")/.."
out=build/shortcuts
rm -rf "$out"
mkdir -p "$out"
failed=0
for f in macos/Resources/Shortcuts/*.shortcut; do
  [ -e "$f" ] || continue
  if ! shortcuts sign --mode anyone --input "$f" --output "$out/$(basename "$f")" >/dev/null 2>&1; then
    failed=1
    rm -f "$out/$(basename "$f")"
  fi
done
[ "$failed" = 0 ] || echo "warning: could not sign some shortcuts (sign in to iCloud); they will not be bundled" >&2
exit 0
