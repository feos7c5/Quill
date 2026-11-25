#!/bin/sh
# Run once on a Mac: fetches the signing engine, builds the Rust core and generates the Xcode project.
set -e
cd "$(dirname "$0")"

ZSIGN_COMMIT="c4ba9da4283031c07efa03bce42c4b8602d22e73"

if [ ! -d Vendor/Zsign ]; then
  mkdir -p Vendor
  git clone --branch package https://github.com/khcrysalis/Zsign-Package Vendor/Zsign
  git -C Vendor/Zsign checkout "$ZSIGN_COMMIT"
fi

if [ ! -d Vendor/QuillCore.xcframework ] || [ "${REBUILD_CORE:-0}" = "1" ]; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "Rust is missing. Install: curl https://sh.rustup.rs -sSf | sh"
    exit 1
  fi
  ./scripts/build-core.sh
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is missing. Install: brew install xcodegen"
  exit 1
fi

xcodegen generate
echo "Done. Open Quill.xcodeproj and pick your team under Signing & Capabilities."
echo "After changing the Rust core: REBUILD_CORE=1 ./setup.sh"
