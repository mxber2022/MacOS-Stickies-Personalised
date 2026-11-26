#!/bin/bash
# Builds DesktopNote and sets it to start automatically at login.
set -euo pipefail
cd "$(dirname "$0")"

APP="$PWD/DesktopNote/DesktopNote.app"
BIN="$APP/Contents/MacOS/DesktopNote"
PLIST="$HOME/Library/LaunchAgents/local.desktopnote.plist"

echo "Building…"
mkdir -p "$APP/Contents/MacOS"
swiftc -O DesktopNote/main.swift -o "$BIN"
codesign --force -s - "$APP"

echo "Setting it to start at login…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.desktopnote</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PL

launchctl bootout "gui/$(id -u)/local.desktopnote" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Done — DesktopNote is running. Look for the note icon in your menu bar."
