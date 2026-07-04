#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/ClaudeMenuBar.app"
BINARY="$APP/Contents/MacOS/ClaudeMenuBar"
PLIST_SRC="$SCRIPT_DIR/com.kota.claude-menu-bar.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.kota.claude-menu-bar.plist"

if [ ! -f "$BINARY" ]; then
  echo "Binary not found. Run build.sh first."
  exit 1
fi

# Stop existing instance if running
launchctl unload "$PLIST_DEST" 2>/dev/null || true

# Install LaunchAgent
cp "$PLIST_SRC" "$PLIST_DEST"
launchctl load "$PLIST_DEST"

echo "Installed and started ClaudeMenuBar as a login item."
echo "It will auto-start on next login."
echo ""
echo "To uninstall:  launchctl unload $PLIST_DEST && rm $PLIST_DEST"
