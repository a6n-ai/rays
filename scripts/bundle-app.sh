#!/usr/bin/env bash
# Builds the engine, the universal macOS app and the CLI into bin/.
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/build-engine.sh

swift_flags=(-c release --package-path macos --arch arm64 --arch x86_64)
swift build "${swift_flags[@]}"
bin_dir="$(swift build "${swift_flags[@]}" --show-bin-path)"

app=bin/Rays.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/Rays" "$app/Contents/MacOS/Rays"
cp macos/Resources/Info.plist "$app/Contents/Info.plist"
# The layered Icon Composer icon compiles to Assets.car (Liquid Glass) plus an .icns fallback.
mkdir -p "$app/Contents/Resources"
# actool resolves relative paths against $PWD, which can be stale; pass absolute ones.
root="$(pwd -P)"
xcrun actool "$root/macos/Resources/AppIcon.icon" --compile "$root/$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$root/build/icon-partial.plist" >/dev/null
[ -f "$app/Contents/Resources/Assets.car" ] || { echo "actool did not produce Assets.car" >&2; exit 1; }

# Universal CLI: the bundled copy is the browser helper, so it must run on Intel Macs too.
cargo build --release -p dl-cli --target aarch64-apple-darwin
cargo build --release -p dl-cli --target x86_64-apple-darwin
lipo -create target/aarch64-apple-darwin/release/dl target/x86_64-apple-darwin/release/dl -output target/release/dl-universal
cp target/release/dl-universal bin/dl
# The browser native host runs this copy, so it must live inside the signed bundle.
cp target/release/dl-universal "$app/Contents/MacOS/dl"
cp -R extension "$app/Contents/Resources/extension"

codesign --force -s - "$app/Contents/MacOS/dl"
codesign --force -s - "$app"

du -sh "$app"
ls -l bin/dl
