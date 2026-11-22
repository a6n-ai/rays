#!/usr/bin/env bash
# Builds the store packages from extension/:
#   build/extension/chrome.zip    Chrome Web Store (no "key": the store holds the private key)
#   build/extension/firefox/      addons.mozilla.org source dir, also zipped as firefox.zip
# Set EXT_VERSION to stamp a version (CI does, since each store needs a higher one every upload).
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/extension
rm -rf "$out" && mkdir -p "$out"

stamp() { # dir, browser
  python3 - "$1/manifest.json" "$2" <<'PY'
import json, os, sys
p, browser = sys.argv[1], sys.argv[2]
m = json.load(open(p))
m.pop("key", None)
if browser == "firefox":
    m["background"].pop("service_worker", None)  # Firefox MV3 runs background "scripts"
else:
    m.pop("browser_specific_settings", None)
    m["background"].pop("scripts", None)
if os.environ.get("EXT_VERSION"):
    m["version"] = os.environ["EXT_VERSION"]
json.dump(m, open(p, "w"), indent=2)
PY
}

for browser in chrome firefox; do
  cp -R extension "$out/$browser"
  stamp "$out/$browser" "$browser"
  (cd "$out/$browser" && zip -qrX "../$browser.zip" . -x '.*')
done
rm -rf "$out/chrome"

npx --yes web-ext@8 lint --source-dir "$out/firefox"
echo "Built $out/chrome.zip and $out/firefox.zip"
