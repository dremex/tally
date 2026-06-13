#!/bin/bash
# Builds Tally and assembles a proper .app bundle (needed for LSUIElement / menu-bar behavior).
# Usage: ./build.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Tally.app"
BUILD_DIR=".build/$CONFIG"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/Tally" "$APP/Contents/MacOS/Tally"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so the app can be launched / granted persistent permissions.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo "==> built ./$APP"
echo "    run with: open ./$APP   (or)   ./$APP/Contents/MacOS/Tally   for console logs"
