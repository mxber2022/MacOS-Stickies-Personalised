#!/bin/bash
# Stops AI Stickies and removes it from login. Your stickers (stickers.json) are kept.
launchctl bootout "gui/$(id -u)/local.desktopnote" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.desktopnote.plist"
echo "AI Stickies stopped and removed from login."
