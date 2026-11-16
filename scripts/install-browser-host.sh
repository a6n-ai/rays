#!/usr/bin/env bash
# Registers bin/dl as the Rays native messaging host for Chrome-family browsers and Firefox.
# Usage: scripts/install-browser-host.sh [chrome-extension-id]
# The extension key lives in build/ (gitignored); its public half is pinned in extension/manifest.json
# so the unpacked Chrome ID is stable. Do not commit the .pem.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DL="$ROOT/bin/dl"
HOST=ai.a6n.rays
FIREFOX_ID=rays@a6n.ai
KEY="$ROOT/build/rays-extension-key.pem"
PUB_DER="$ROOT/build/rays-extension-pub.der"
MANIFEST="$ROOT/extension/manifest.json"

[[ -x "$DL" ]] || { echo "missing $DL: build the CLI first" >&2; exit 1; }

if [[ ! -f "$KEY" ]]; then
  openssl genrsa -out "$KEY" 2048 2>/dev/null
  chmod 600 "$KEY"
  echo "generated $KEY"
fi
openssl rsa -in "$KEY" -pubout -outform DER -out "$PUB_DER" 2>/dev/null
PUB_B64="$(openssl base64 -A -in "$PUB_DER")"
DEFAULT_ID="$(shasum -a 256 "$PUB_DER" | cut -c1-32 | tr '0123456789abcdef' 'abcdefghijklmnop')"
ID="${1:-$DEFAULT_ID}"

if ! grep -qF "$PUB_B64" "$MANIFEST"; then
  echo "warning: extension/manifest.json \"key\" does not match $KEY; set it to:" >&2
  echo "  \"key\": \"$PUB_B64\"" >&2
fi

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
