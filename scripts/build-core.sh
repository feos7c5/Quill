#!/bin/sh
# Builds the Rust core for iPhone (and simulator) and packages it as Vendor/QuillCore.xcframework.
# Requires Xcode and Rust (rustup). macOS only.
# QUILL_DEVICE_ONLY=1 builds for the device only (faster, e.g. in CI).
set -eu
cd "$(dirname "$0")/../QuillCore"

export IPHONEOS_DEPLOYMENT_TARGET=27.0
rustup target add aarch64-apple-ios aarch64-apple-ios-sim >/dev/null

cargo build --release --locked --target aarch64-apple-ios
set -- -library target/aarch64-apple-ios/release/libquill_core.a -headers include
if [ "${QUILL_DEVICE_ONLY:-0}" != "1" ]; then
  cargo build --release --locked --target aarch64-apple-ios-sim
  set -- "$@" -library target/aarch64-apple-ios-sim/release/libquill_core.a -headers include
fi

OUT=../Vendor/QuillCore.xcframework
rm -rf "$OUT"
xcodebuild -create-xcframework "$@" -output "$OUT"
echo "Done: $OUT"
