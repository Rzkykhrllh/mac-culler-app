#!/bin/zsh
# Builds PhotoCuller (Release) and installs it in /Applications — no Xcode window needed.
# Usage: scripts/install.sh [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
DD=build/Install
APP="$DD/Build/Products/Release/PhotoCuller.app"
DEST=/Applications/PhotoCuller.app

echo "▸ Generating project"
xcodegen generate --quiet
echo "▸ Building Release (build $BUILD)…"
if ! xcodebuild -project PhotoCuller.xcodeproj -scheme PhotoCuller -configuration Release \
        -derivedDataPath "$DD" CURRENT_PROJECT_VERSION="$BUILD" build > "$DD.log" 2>&1; then
    grep -E "error:" "$DD.log" | sort -u | head -20
    echo "✗ Build failed — full log: $DD.log"
    exit 1
fi

# Quit the installed copy if it is running (marks are saved continuously; this just lets us replace it).
if pgrep -f "$DEST/Contents/MacOS/PhotoCuller" > /dev/null; then
    echo "▸ Quitting the running PhotoCuller"
    osascript -e 'tell application id "com.byairu.photoculler" to quit' || true
    for _ in {1..20}; do pgrep -f "$DEST/Contents/MacOS/PhotoCuller" > /dev/null || break; sleep 0.5; done
fi

echo "▸ Installing to $DEST"
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --strict "$DEST" && echo "✓ Signature OK"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist")
echo "✓ PhotoCuller $VERSION ($BUILD) installed — open it from Launchpad, Spotlight or the Dock."

[[ "${1:-}" == "--no-open" ]] || open "$DEST"
