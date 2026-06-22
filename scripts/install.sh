#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/Statoise Git.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: 'Statoise Git.app' not found in the same directory as this script."
  exit 1
fi
xattr -cr "$APP_PATH"
mkdir -p ~/Applications
rm -rf ~/Applications/"Statoise Git.app"
cp -R "$APP_PATH" ~/Applications/
open ~/Applications/"Statoise Git.app"
echo "Installed successfully."
