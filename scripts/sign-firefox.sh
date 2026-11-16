#!/usr/bin/env bash
# Signs the extension on addons.mozilla.org as an unlisted (self-distributed) add-on and writes
# build/firefox/rays.xpi. Firefox and Zen install a signed .xpi permanently with one "Add" click.
#
# One-time setup (keys stay in your login Keychain, never in the repo):
#   1. Create API credentials at https://addons.mozilla.org/developers/addon/api/key/
#   2. security add-generic-password -s rays-amo -a jwt-issuer -w   # paste the "JWT issuer"
#   3. security add-generic-password -s rays-amo -a jwt-secret -w   # paste the "JWT secret"
set -euo pipefail
cd "$(dirname "$0")/.."

issuer="$(security find-generic-password -s rays-amo -a jwt-issuer -w)"
secret="$(security find-generic-password -s rays-amo -a jwt-secret -w)"

out=build/firefox
rm -rf "$out" && mkdir -p "$out"
# Firefox ignores Chrome's "key" field and service_worker; strip both so AMO's linter passes cleanly.
src="$out/src"
cp -R extension "$src"
python3 - "$src/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m.pop("key", None)
m["background"].pop("service_worker", None)  # Firefox MV3 runs background "scripts"
json.dump(m, open(p, "w"), indent=2)
PY

npx --yes web-ext@8 lint --source-dir "$src" --self-hosted
WEB_EXT_API_KEY="$issuer" WEB_EXT_API_SECRET="$secret" \
  npx --yes web-ext@8 sign --channel unlisted --source-dir "$src" --artifacts-dir "$out"

xpi="$(ls -t "$out"/*.xpi | head -1)"
mv "$xpi" "$out/rays.xpi"
echo "Signed: $out/rays.xpi"
