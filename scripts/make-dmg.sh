#!/bin/zsh
# Packs the installed-style Release build into dist/PhotoCuller-<version>.dmg (drag to Applications).
# Build first with scripts/install.sh. Note: without an Apple Developer ID + notarization, other Macs
# will warn on first launch (right-click ▸ Open, or System Settings ▸ Privacy & Security ▸ Open Anyway).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Install/Build/Products/Release/PhotoCuller.app
[[ -d "$APP" ]] || { echo "Run scripts/install.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/PhotoCuller.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
OUT="dist/PhotoCuller-$VERSION-$BUILD.dmg"
rm -f "$OUT"
hdiutil create -volname "PhotoCuller $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT" > /dev/null
rm -rf "$STAGE"
echo "✓ $OUT"
