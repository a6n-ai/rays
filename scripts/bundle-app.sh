#!/usr/bin/env bash
# Builds the engine, the universal macOS app and the CLI into bin/.
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/build-engine.sh

# One certificate for every release keeps the code identity the same across updates, so macOS
# keeps folder access and Keychain items. CI imports it from secrets; locally it's in the login keychain.
identity="${RAYS_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q '"Rays"'; then identity="Rays"; else identity=-; fi
fi
[ "$identity" = - ] && echo "warning: signing ad hoc; updates will ask for folder and Keychain access again" >&2

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

# SwiftPM compiles the App Intents but does not extract their metadata, so Shortcuts would not see them.
# The constvalues of one architecture describe the same intents as the other.
mkdir -p build/intents
fd -e swift . macos/Sources/Rays -a >build/intents/sources.txt
fd -e swiftconstvalues -p 'Release/.*/arm64/' . "$root/macos/.build/out/Intermediates.noindex/Rays.build" -a >build/intents/constvalues.txt
[ -s build/intents/constvalues.txt ] || { echo "no swiftconstvalues for arm64 under macos/.build" >&2; exit 1; }
xcrun appintentsmetadataprocessor --output "$root/$app/Contents/Resources" \
  --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" --module-name Rays \
  --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macos26.0 \
  --source-file-list "$root/build/intents/sources.txt" --swift-const-vals-list "$root/build/intents/constvalues.txt"
[ -d "$app/Contents/Resources/Metadata.appintents" ] || { echo "appintentsmetadataprocessor produced no Metadata.appintents" >&2; exit 1; }

# Universal CLI: the bundled copy is the browser helper, so it must run on Intel Macs too.
cargo build --release -p dl-cli --target aarch64-apple-darwin
cargo build --release -p dl-cli --target x86_64-apple-darwin
lipo -create target/aarch64-apple-darwin/release/dl target/x86_64-apple-darwin/release/dl -output target/release/dl-universal
cp target/release/dl-universal bin/dl
# The browser native host runs this copy, so it must live inside the signed bundle.
cp target/release/dl-universal "$app/Contents/MacOS/dl"
# The sorter runs from the bundle and finds extract next to itself, so both are universal and signed like dl.
cargo build --release -p sorter -p extract --target aarch64-apple-darwin
cargo build --release -p sorter -p extract --target x86_64-apple-darwin
for bin in sorter extract; do
  lipo -create "target/aarch64-apple-darwin/release/$bin" "target/x86_64-apple-darwin/release/$bin" -output "target/release/$bin-universal"
  cp "target/release/$bin-universal" "$app/Contents/MacOS/$bin"
  codesign --force -s "$identity" "$app/Contents/MacOS/$bin"
done

codesign --force -s "$identity" "$app/Contents/MacOS/dl"
# Share extension: universal build, linked as an appex (entry _NSExtensionMain), signed before the app.
appex="$app/Contents/PlugIns/RaysShare.appex"
mkdir -p "$appex/Contents/MacOS" build/share
for arch in arm64 x86_64; do
  xcrun swiftc -parse-as-library -module-name RaysShare -application-extension -target "$arch-apple-macos26.0" \
    -Xlinker -e -Xlinker _NSExtensionMain -o "build/share/RaysShare-$arch" macos/ShareExtension/ShareViewController.swift
done
lipo -create build/share/RaysShare-arm64 build/share/RaysShare-x86_64 -output "$appex/Contents/MacOS/RaysShare"
cp macos/ShareExtension/Info.plist "$appex/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  plutil -replace "$key" -string "$(plutil -extract "$key" raw macos/Resources/Info.plist)" "$appex/Contents/Info.plist"
done
codesign --force -s "$identity" --entitlements macos/ShareExtension/RaysShare.entitlements "$appex"

codesign --force -s "$identity" "$app"

du -sh "$app"
ls -l bin/dl
