<p align="center"><img src="DesktopNote/icon-preview.png" width="160" alt="DesktopNote icon"></p>

# DesktopNote

Sticky notes that live on your macOS wallpaper. Type straight onto the desktop, add as many stickers as you like, set reminders, and everything saves itself automatically.

It's a single Swift file with no dependencies. It uses about 20 MB of memory and no CPU while idle.

## Features

- **Stickers on your wallpaper.** They sit above the desktop icons and behind your normal windows, and they show on every Space.
- **Autosave.** Text, position and size are saved as you type, move or resize, and everything comes back after a restart.
- **Frosted glass look.** The stickers are see-through, and the controls (drag bar, **+**, 🔔, **×**, resize corner) only appear when you click a sticker.
- **Matches your wallpaper.** Light wallpapers get light stickers with dark text, and dark wallpapers get dark stickers with white text. This updates within about 3 seconds when you change the wallpaper. You can also force Light or Dark.
- **Handwriting fonts.** Choose from Noteworthy, Bradley Hand, Chalkboard, Marker Felt, Snell Roundhand, or plain text.
- **Reminders.** Set a date and time on any sticker. When it's due you get a notification and a chime that repeats for 30 seconds, and the sticker jumps in front of everything with a glowing orange edge until you click it. Reminders that came due while your Mac was asleep go off as soon as it wakes.
- **Hide or show all stickers** with one click. The app remembers which you chose.
- **Change the wallpaper** from the menu. The app keeps a copy of the image so the wallpaper survives if the original is deleted.
- **Stays on screen.** Stickers can't get lost under the menu bar or off the edge of the screen.

## Requirements

- macOS 12 or later
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
| Hide or show everything | Menu bar icon → **Hide all stickers** / **Show all stickers** |
| Change wallpaper, sticker style or font | Menu bar icon → **Change wallpaper…** / **Sticker style** / **Font** |
| Find a lost sticker | Menu bar icon → **Line up all stickers** |

## Where your data lives

| What | Where |
| --- | --- |
| Sticker text, positions and reminders | `~/Desktop/life/stickers.json` |
| Wallpaper copies | `~/Desktop/life/wallpapers/` |
| Font, style and hidden setting | macOS preferences (`local.desktopnote`) |

`stickers.json` and `wallpapers/` are listed in `.gitignore`, so your personal notes are never committed.

> The data folder is fixed to `~/Desktop/life`. To use a different folder, change `lifeDir` at the top of `DesktopNote/main.swift` and run `./install.sh` again.

## Uninstall

```bash
./uninstall.sh
```

This stops the app and removes the login item. Your `stickers.json` is kept.

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
