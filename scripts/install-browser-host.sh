#!/usr/bin/env bash
# Registers bin/dl as the Rays native messaging host for Chrome-family browsers and Firefox.
# Usage: scripts/install-browser-host.sh [chrome-extension-id]
# The Chrome Web Store's public key is pinned in extension/manifest.json, so the unpacked ID
# matches the store ID. Google holds the private key.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DL="$ROOT/bin/dl"
HOST=ai.a6n.rays
FIREFOX_ID=rays@a6n.ai
MANIFEST="$ROOT/extension/manifest.json"

[[ -x "$DL" ]] || { echo "missing $DL: build the CLI first" >&2; exit 1; }

PUB_B64="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["key"])' "$MANIFEST")"
DEFAULT_ID="$(printf %s "$PUB_B64" | openssl base64 -d -A | shasum -a 256 | cut -c1-32 | tr '0123456789abcdef' 'abcdefghijklmnop')"
ID="${1:-$DEFAULT_ID}"

write_manifest() { # dir, browser-specific allow-list line
  mkdir -p "$1"
  cat > "$1/$HOST.json" <<JSON
{
  "name": "$HOST",
  "description": "Rays download manager",
  "path": "$DL",
  "type": "stdio",
  $2
}
JSON
  echo "wrote $1/$HOST.json"
}

CHROME_ALLOW="\"allowed_origins\": [\"chrome-extension://$ID/\"]"
for base in "Google/Chrome" "Chromium" "BraveSoftware/Brave-Browser" "Microsoft Edge"; do
  support="$HOME/Library/Application Support/$base"
  [[ -d "$support" ]] || continue
  write_manifest "$support/NativeMessagingHosts" "$CHROME_ALLOW"
done

write_manifest "$HOME/Library/Application Support/Mozilla/NativeMessagingHosts" \
  "\"allowed_extensions\": [\"$FIREFOX_ID\"]"

echo "Chrome extension ID: $ID"
