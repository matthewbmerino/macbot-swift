#!/bin/bash
# Build macbot and wrap it in a proper .app bundle so macOS can
# persistently grant Screen Recording, Accessibility, and other
# permissions. Without a bundle, permissions prompt every launch.

set -euo pipefail

APP_NAME="macbot"
BUNDLE_DIR="$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building macbot..."
swift build -c release 2>&1 | tail -5

echo "Creating $BUNDLE_DIR..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Copy executable
cp .build/release/Macbot "$MACOS/Macbot"

# Copy Info.plist
cp Macbot/Info.plist "$CONTENTS/Info.plist"

# Copy resources (Metal shaders, Soul.md, etc.)
if [ -d ".build/release/Macbot_Macbot.bundle" ]; then
    cp -R .build/release/Macbot_Macbot.bundle "$RESOURCES/"
fi

# Sign with ad-hoc signature (required for Accessibility/Screen Recording)
codesign --force --deep --sign - "$BUNDLE_DIR"

echo ""
echo "Done! To run:"
echo "  open $BUNDLE_DIR"
echo ""
echo "To grant permissions:"
echo "  1. Open macbot.app"
echo "  2. Go to System Settings > Privacy & Security"
echo "  3. Enable macbot under Screen Recording, Accessibility, etc."
echo "  4. Permissions will persist across launches."
echo ""
echo "To install in Applications:"
echo "  cp -R $BUNDLE_DIR /Applications/"
