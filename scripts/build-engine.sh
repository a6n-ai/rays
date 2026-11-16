#!/usr/bin/env bash
# Builds the dl engine as a universal static library and the UniFFI Swift bindings,
# then packages them as build/dl_engineFFI.xcframework for the macOS app.
set -euo pipefail

cd "$(dirname "$0")/.."

for target in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target add "$target"
  cargo build --release -p dl-engine --target "$target"
done

mkdir -p build/swift build/headers macos/Sources/Rays/Generated
lipo -create -output build/libdl_engine.a \
  target/aarch64-apple-darwin/release/libdl_engine.a \
  target/x86_64-apple-darwin/release/libdl_engine.a

cargo run -q -p uniffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/libdl_engine.a \
  --language swift --out-dir build/swift

# The modulemap must be named module.modulemap and the module name must match the binary target.
cp build/swift/dl_engineFFI.h build/headers/
cp build/swift/dl_engineFFI.modulemap build/headers/module.modulemap
cp build/swift/dl_engine.swift macos/Sources/Rays/Generated/

rm -rf build/dl_engineFFI.xcframework
xcodebuild -create-xcframework \
  -library build/libdl_engine.a \
  -headers build/headers \
  -output build/dl_engineFFI.xcframework
