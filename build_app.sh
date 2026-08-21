#!/bin/bash
# Builds GraphicEQ in release mode and assembles it into a proper GraphicEQ.app bundle,
# ad-hoc codesigned so TCC (microphone permission) and AudioUnit device binding work correctly.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GraphicEQ"
BUNDLE="$APP_NAME.app"

echo "Building release binary..."
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

if [ ! -f "$BIN_PATH" ]; then
    echo "Build did not produce expected binary at $BIN_PATH" >&2
    exit 1
fi

echo "Assembling $BUNDLE..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

echo "Ad-hoc codesigning..."
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --verbose "$BUNDLE"

echo
echo "Built: $(pwd)/$BUNDLE"
echo "First launch: right-click the app -> Open (Gatekeeper will warn since it's unsigned/unnotarized)."
