# YKShot

A small native macOS screenshot app that lives in the menu bar. Take a screenshot, mark it up, then copy or save it.

Plain Swift and AppKit, with no Xcode project and no dependencies.

## Features

- **Area capture**: drag to select an area, press Space to capture a single window, or Esc to cancel. This uses macOS's own selection tool.
- **Full-page capture**: scrolls the browser window you're using, takes a series of screenshots and joins them into one long image. It works in any browser and on sites you're logged into. Only the page is captured, not the browser's tabs or toolbar.
- **App capture**: captures the whole screen, keeps the app in front sharp and blurs everything else (desktop, other apps' windows).
- **Editor**: pen, box, arrow, text comments, Blur (hides what's inside a box) and Focus (blurs and dims everything outside a box). Pick from 8 preset colours, undo, and pinch to zoom.
- **Copy and Save**: both keep full Retina resolution. For tall images, Copy also puts the PNG file on the clipboard, so chat apps attach the original file instead of shrinking it.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌘9 | Capture an area (also works while YKShot's own menu is open) |
| ⇧⌘9 | Capture a full scrolling page |
| ⌥⌘9 | Capture the screen with everything except the front app blurred |
| ⌘Z / ⌘C / ⌘S | Undo / Copy / Save in the editor |

All of these are also in the menu-bar menu. The shortcuts work from any app. They take ⌘9 away from other apps, so in browsers it no longer jumps to the last tab.

## Install

Requirements: macOS 14 or later, and Apple's Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/KaskoYurii/yk-shot.git && cd yk-shot
./build.sh
```

`build.sh` compiles the app, installs it to `/Applications/YKShot.app` and starts it. Run it again after any change to rebuild and reinstall. `./build.sh icon` also redraws the app icon from `icon.swift`.

To start YKShot when you log in, add it in System Settings → General → Login Items.

### Permissions

The first time you capture, macOS asks for these in System Settings → Privacy & Security:

- **Screen & System Audio Recording**: needed for every capture.
- **Accessibility**: needed for full-page capture, so YKShot can scroll the browser and find where the page sits in the window. Also used to catch ⌘9 while YKShot's own menu is open.

If a permission is missing, YKShot says which one and links to the right Settings page. After turning on Screen Recording, quit YKShot and open it again.

The app is signed with a fixed identity (`local.ykshot`), so rebuilding doesn't reset these permissions.

## How full-page capture works

1. Finds the window in front and asks it (through Accessibility) where the page area is.
2. Jumps to the top of the page, then scrolls half a page at a time. The mouse stays on the scrollbar strip, so the page doesn't show hover effects.
3. Compares each screenshot with the previous one to work out how far the page moved, and finds headers or footers that stay in place.
4. Adds only the new rows from each screenshot, until the page stops moving.

Rows are compared in 32 separate blocks with a small tolerance. A hover effect, a moving ticker or an image that loads late only affects its own blocks, so the overlap still matches.

### Known limits

- Pages that scroll inside a panel (some web apps, Gmail) only capture that panel, and only if it scrolls from the right edge.
- Animated content is frozen at whatever moment each screenshot caught it.
- A blank stretch taller than about 1.5 screens looks like the end of the page.
- Long pages stop at 60 steps, about 30 screens. To change that, edit `maxFrames` in `PageCapture.swift`.
- Screenshots have your screen's resolution. Zoom the browser in (⌘+) before capturing if you need more detail.

## Project layout

```
main.swift          app, menu-bar icon, shortcuts, editor, area and app capture
PageCapture.swift   full-page capture: scrolling, finding the overlap, joining
icon.swift          draws the app icon (AppIcon.icns is built from it)
build.sh            build, sign, install, relaunch
tests/main.swift    self-check for the overlap matching
```

## Tests

```sh
swiftc PageCapture.swift tests/main.swift -o /tmp/ykcheck && /tmp/ykcheck
```

## Uninstall

Quit YKShot from the menu-bar icon, then delete it and reset its permissions:

```sh
rm -rf /Applications/YKShot.app
tccutil reset ScreenCapture local.ykshot
tccutil reset Accessibility local.ykshot
```

## License

[MIT](LICENSE): free to use, change and share, including in commercial projects. Keep the copyright notice.
