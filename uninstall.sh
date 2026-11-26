#!/bin/bash
# Stops DesktopNote and removes it from login. Your stickers (stickers.json) are kept.
launchctl bootout "gui/$(id -u)/local.desktopnote" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.desktopnote.plist"
echo "DesktopNote stopped and removed from login."
