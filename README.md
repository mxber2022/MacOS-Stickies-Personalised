<p align="center"><img src="DesktopNote/icon-preview.png" width="160" alt="AI DesktopNote icon"></p>

# AI DesktopNote

Sticky notes that live on your macOS wallpaper. Type straight onto the desktop, add as many stickers as you like, set reminders, and ask Claude (AI) anything from any sticker. Everything saves itself automatically.

It's a single Swift file with no dependencies. On its own it uses about 30 MB of memory and no CPU while idle. Each X feed panel is a real web page and adds roughly 350 MB, plus a short burst of CPU when it refreshes (once an hour). While Claude is answering a question, Claude Code runs in the background for a few seconds and briefly uses a few hundred MB more.

## Features

- **Stickers on your wallpaper.** They sit above the desktop icons and behind your normal windows, and they show on every Space.
- **AI assistant on every sticker.** Click ✨ to chat with Claude in a window beside the sticker. Each sticker has its own Claude that remembers your conversation and can see what's written on that sticker. See [Ask Claude (AI)](#ask-claude-ai).
- **Autosave.** Text, position and size are saved as you type, move or resize, and everything comes back after a restart.
- **Frosted glass look.** The stickers are see-through, and the controls (drag bar, **+**, 🔔, ✨, **×**, resize corner) only appear when you click a sticker.
- **Matches your wallpaper.** Light wallpapers get light stickers with dark text, and dark wallpapers get dark stickers with white text. This updates within about 3 seconds when you change the wallpaper. You can also force Light or Dark.
- **Handwriting fonts.** Noteworthy is the default. You can also choose Bradley Hand, Chalkboard, Marker Felt, Snell Roundhand, or plain text.
- **Reminders.** Set a date and time on any sticker. When it's due you get a notification and a chime that repeats for 30 seconds, and the sticker jumps in front of everything with a glowing orange edge until you click it. Reminders that came due while your Mac was asleep go off as soon as it wakes.
- **Hide or show everything** with one click: stickers and X feeds. While they're hidden, the menu bar icon changes to a crossed-out eye. The app remembers which you chose.
- **Change the wallpaper** from the menu. The app keeps a copy of the image so the wallpaper survives if the original is deleted.
- **X (Twitter) feeds.** Pin someone's X profile to your desktop in a frosted panel. By default it shows only their tweets: X's menus, profile header, suggestions, profile pictures, the person's name and @handle on their own posts (only the time is shown), the pinned post, the Grok and **…** buttons, and the reply/repost/like row under each post are hidden. It refreshes every hour while you're not using it, and you stay logged in between restarts.
- **Stays on screen.** Stickers and feed panels can't get lost under the menu bar or off the edge of the screen.

## Ask Claude (AI)

Every sticker has its own AI assistant, powered by Claude.

1. Click a sticker, then click **✨** in its top bar.
2. A chat window opens beside the sticker. Type a question and press Enter.
3. Claude answers, usually within a few seconds. Ask follow-up questions in the same chat.

What it can do:

- **Knows your note.** Claude sees what's written on that sticker, so you can ask things like "what can I cook with this?" on a grocery list, "fix the typos", or "turn this into a plan".
- **Remembers.** Each sticker has its own conversation, and it's saved, so it's still there after you close the chat or restart your Mac. The pencil icon starts a fresh conversation.
- **Looks things up.** Claude can search the web for current information.
- **Stays in its lane.** It can't read your files, change your notes or run anything on your Mac. Copy an answer into your note yourself if you want it there.

The chat window is frosted glass with a Siri-style rainbow border that flows faster while Claude is thinking. **Esc** or **×** closes it.

How it connects: the app runs [Claude Code](https://claude.com/claude-code) in the background with `claude -p`, using the account you're already logged in with. There's no API key to set up, and questions count toward your Claude plan. Your plugins, hooks and MCP servers aren't loaded for these questions.

Privacy: each question sends that sticker's text and your question to Anthropic, the same as using Claude Code. Your other stickers aren't sent.

## Requirements

- macOS 12 or later (the X feed filter needs macOS 12.3 or later)
- To ask Claude on stickers: [Claude Code](https://claude.com/claude-code) installed and logged in (run `claude` once in Terminal to log in)
- Swift compiler from the Xcode Command Line Tools. Install it with `xcode-select --install` if `swiftc` isn't found.

## Install

```bash
git clone https://github.com/mxber2022/MacOS-Stickies-Personalised.git ~/Desktop/life
cd ~/Desktop/life
./install.sh
```

`install.sh` builds the app, signs it locally, and adds a login item (`~/Library/LaunchAgents/local.desktopnote.plist`) so it starts every time you log in. Run it again whenever you change `main.swift`.

The first time you set a reminder, macOS asks for permission to show notifications. Click **Allow**.

## Using it

| To… | Do this |
| --- | --- |
| Write | Click a sticker and type |
| Move a sticker | Click it, then drag the bar at the top |
| Resize | Drag the bottom-right corner |
| Add a sticker | **+** on any sticker, or 📝 menu bar icon → **New sticker** |
| Delete a sticker | **×** (asks first if it has writing on it) |
| Set a reminder | 🔔 → pick a date and time → **Set reminder** |
| Stop a ringing reminder | Click the sticker |
| Ask Claude | ✨ on the sticker opens the chat beside it (it moves with the sticker). Type and press Enter; answers usually take a few seconds. The pencil icon starts a new conversation, **×** or Esc closes the chat. You can select and copy answers. |
| Hide or show everything | Menu bar icon → **Hide all stickers** / **Show all stickers** |
| Change wallpaper, sticker style or font | Menu bar icon → **Change wallpaper…** / **Sticker style** / **Font** |
| Show someone's X posts | Menu bar icon → **Add X feed…** → type their username. Log in to X inside the panel once. |
| Use an X feed panel | Click the panel to show its top bar and resize corner (they hide again when you click elsewhere). Drag the top bar to move it. Top bar: **‹** back, filter icon switches between **tweets only** (default) and the full page, **⟳** back to the profile and refresh, **×** removes the feed. Switch to the full page to log in. |
| Find a lost sticker | Menu bar icon → **Line up all stickers** |
| Open the saved file or quit | Menu bar icon → **Show saved file in Finder** / **Quit AI DesktopNote** |

## Where your data lives

| What | Where |
| --- | --- |
| Sticker text, positions and reminders | `~/Desktop/life/stickers.json` |
| X feeds you've added | `~/Desktop/life/feeds.json` |
| Claude conversations | One per sticker: the messages are in `stickers.json`, and Claude's memory of them is in Claude Code's history for `~/Library/Application Support/DesktopNote/agent` |
| X login | Stored by macOS for this app only (WebKit data for `local.desktopnote`) |
| Wallpaper copies | `~/Desktop/life/wallpapers/` |
| Font, style and hidden setting | macOS preferences (`local.desktopnote`) |

`stickers.json`, `feeds.json` and `wallpapers/` are listed in `.gitignore`, so your personal notes are never committed.

> The data folder is fixed to `~/Desktop/life`. To use a different folder, change `lifeDir` at the top of `DesktopNote/main.swift` and run `./install.sh` again.

## Uninstall

```bash
./uninstall.sh
```

This stops the app and removes the login item. Your `stickers.json` and `feeds.json` (including your Claude chats) are kept.

## Project layout

```
DesktopNote/
  main.swift                      # the whole app
  make-icon.swift                 # draws the app icon (swift DesktopNote/make-icon.swift)
  icon-preview.png                # 1024px preview of the icon
  DesktopNote.app/Contents/
    Info.plist                    # app bundle settings (no Dock icon)
    Resources/AppIcon.icns        # the app icon
install.sh                        # build + start at login
uninstall.sh                      # stop + remove from login
```
