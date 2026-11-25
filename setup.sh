#!/bin/sh
# Einmalig auf dem Mac ausführen: holt die Signier-Engine, baut den Rust-Kern und erzeugt das Xcode-Projekt.
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
    echo "Rust fehlt. Installation: curl https://sh.rustup.rs -sSf | sh"
    exit 1
  fi
  ./scripts/build-core.sh
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen fehlt. Installation: brew install xcodegen"
  exit 1
fi

xcodegen generate
echo "Fertig. Quill.xcodeproj öffnen, unter Signing & Capabilities das eigene Team wählen."
echo "Nach Änderungen am Rust-Kern: REBUILD_CORE=1 ./setup.sh"
