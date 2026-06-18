#!/bin/bash
set -euo pipefail

# Usage: ./scripts/create-dmg.sh <path-to-app> <output-dir>

APP_PATH="${1:?Usage: create-dmg.sh <app-path> <output-dir>}"
OUTPUT_DIR="${2:-.}"

APP_NAME=$(basename "$APP_PATH" .app)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"

echo "Creating DMG: ${DMG_NAME}"
echo "  App: ${APP_PATH}"
echo "  Output: ${DMG_PATH}"

# Create a temporary directory for DMG contents
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Copy app to temp dir
cp -R "$APP_PATH" "$TEMP_DIR/"

# Create a symlink to /Applications for drag-install
ln -s /Applications "$TEMP_DIR/Applications"

# Create DMG
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$TEMP_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo ""
echo "DMG created successfully:"
echo "  ${DMG_PATH}"
echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
