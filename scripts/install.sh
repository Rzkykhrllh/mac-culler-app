#!/bin/zsh
# Builds Pickture (Release) and installs it in /Applications — no Xcode window needed.
# Usage: scripts/install.sh [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
DD=build/Install
APP="$DD/Build/Products/Release/Pickture.app"
DEST=/Applications/Pickture.app

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
if pgrep -f "/Applications/(Pickture|PhotoCuller)\.app/Contents/MacOS/" > /dev/null; then
    echo "▸ Quitting the running app"
    osascript -e 'tell application id "com.byairu.photoculler" to quit' || true
    for _ in {1..20}; do pgrep -f "/Applications/(Pickture|PhotoCuller)\.app/Contents/MacOS/" > /dev/null || break; sleep 0.5; done
fi

echo "▸ Installing to $DEST"
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --strict "$DEST" && echo "✓ Signature OK"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist")
echo "✓ Pickture $VERSION ($BUILD) installed — open it from Launchpad, Spotlight or the Dock."

# The app was called PhotoCuller before: move that old copy to the Trash (same app, same settings).
OLD=/Applications/PhotoCuller.app
if [[ -d "$OLD" ]]; then
    mv "$OLD" "$HOME/.Trash/PhotoCuller $(date +%Y%m%d-%H%M%S).app" && echo "▸ Moved the old PhotoCuller.app to the Trash"
fi

[[ "${1:-}" == "--no-open" ]] || open "$DEST"
