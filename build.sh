#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/ClaudeMenuBar.app"
BINARY="$APP/Contents/MacOS/ClaudeMenuBar"

echo "Building ClaudeMenuBar..."
swiftc "$SCRIPT_DIR/ClaudeMenuBar.swift" \
  -o "$BINARY" \
  -framework AppKit \
  -framework Foundation

echo "Build complete: $APP"
echo ""
echo "Run with:  open '$APP'"
echo "Or install as login item — see install.sh"
