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

# CI passes the keys as env vars (repo secrets); locally they come from the login Keychain.
issuer="${WEB_EXT_API_KEY:-$(security find-generic-password -s rays-amo -a jwt-issuer -w)}"
secret="${WEB_EXT_API_SECRET:-$(security find-generic-password -s rays-amo -a jwt-secret -w)}"

out=build/firefox
rm -rf "$out" && mkdir -p "$out"
# Firefox ignores Chrome's "key" field and service_worker; strip both so AMO's linter passes cleanly.
src="$out/src"
cp -R extension "$src"
python3 - "$src/manifest.json" <<'PY'
import json, os, sys
p = sys.argv[1]
m = json.load(open(p))
m.pop("key", None)
m["background"].pop("service_worker", None)  # Firefox MV3 runs background "scripts"
# AMO signs each version once; CI stamps a fresh one per run.
if os.environ.get("EXT_VERSION"):
    m["version"] = os.environ["EXT_VERSION"]
json.dump(m, open(p, "w"), indent=2)
PY

npx --yes web-ext@8 lint --source-dir "$src" --self-hosted
WEB_EXT_API_KEY="$issuer" WEB_EXT_API_SECRET="$secret" \
  npx --yes web-ext@8 sign --channel unlisted --source-dir "$src" --artifacts-dir "$out"

xpi="$(ls -t "$out"/*.xpi | head -1)"
mv "$xpi" "$out/rays.xpi"
echo "Signed: $out/rays.xpi"
