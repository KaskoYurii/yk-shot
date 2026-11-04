# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

YKShot: a macOS 14+ menu-bar screenshot app. Plain Swift + AppKit, compiled directly with `swiftc`. No Xcode project, no Package.swift, no dependencies. Keep it that way.

## Commands

```sh
./build.sh          # compile, ad-hoc sign, install to /Applications/YKShot.app, kill old copy, relaunch
./build.sh icon     # also redraw AppIcon.icns from icon.swift (it's redrawn automatically if missing)
swiftc PageCapture.swift tests/main.swift -o /tmp/ykcheck && /tmp/ykcheck   # the only test; prints "ok"
```

- The app binary is just `swiftc -O main.swift PageCapture.swift`. Any new source file has to be added to that line in `build.sh` (and to the test command if the tests need it).
- `Info.plist` is generated inside `build.sh` (version is `VERSION=` there, `LSUIElement` = no Dock icon). `YKShot.app/` and `AppIcon.icns` are build output and gitignored.
- Tests are plain top-level `assert`s in `tests/main.swift`, with no framework. They only cover `PageCapture.align` (the stitching math). Anything that needs screen capture, Accessibility or the UI can't be tested here, so check it by running `./build.sh` and trying it.
- Signing uses a fixed designated requirement (`identifier "local.ykshot"`) so Screen Recording and Accessibility permissions survive rebuilds. Don't change the bundle id or the codesign line casually: users would have to grant permissions again.

## Architecture

- **`main.swift`**: everything except full-page capture. Top-level code at the bottom starts `NSApplication` with the `App` delegate.
  - `App` owns the status-bar item, menu, single editor window and toolbar. Global hotkeys are Carbon `RegisterEventHotKey` on `9` with ⌘ / ⇧⌘ / ⌥⌘. While YKShot's own menu is open, Carbon hotkeys don't fire, so `menuWillOpen` installs a temporary `CGEvent` tap to catch ⌘9. That's why Accessibility is involved there.
  - Three capture paths all end in `show(_:reopen:)`, which loads the image into the editor:
    - Area: runs `/usr/sbin/screencapture -i` to a temp file. Drag, Space and Esc are macOS's own UI.
    - App: `AppCapture.run` blurs everything except the frontmost app's windows.
    - Page: `PageCapture.run`.
    - App and page captures go through `inBackground`, which hides the editor window and runs the work off the main thread. `pageBusy` / `running` stop captures from overlapping.
  - `permitted(accessibility:)` checks Screen Recording (and, if asked, Accessibility) before every capture. When one is missing it shows an alert that links to the right Settings pane. Keep this behavior for any new capture path.
  - Editor: `Canvas` (NSView) draws the image, then a list of `Mark`s (`Tool`: pen/rect/arrow/text/blur/focus) on top. Marks stay as vectors until export. `png()` renders the view with `cacheDisplay` at full resolution, so Copy and Save get exactly what's on screen. `Stage` is the padded gray backdrop, and `CenteringClipView` keeps the image centred in the magnifiable `NSScrollView`.
- **`PageCapture.swift`**: full-page scrolling capture, written as an `enum` with static functions.
  - Finds the topmost window (`CGWindowListCopyWindowInfo`) and asks it through Accessibility (`webArea`, which sets `AXManualAccessibility` / enhanced UI on browsers) where the page area is.
  - Parks the cursor on the scrollbar strip (cut out of the shot) and sends pixel scroll-wheel `CGEvent`s.
  - Grabs frames with `screencapture -R`, then stitches them.
  - `align(prev:cur:expected:)` is the core. Each row is reduced to a signature of `cols` = 32 block brightness values. It detects sticky header and footer rows, then finds the scroll shift with a ±2 tolerance and a `minScore` match ratio. It returns `nil` at the end of the page or when nothing matches. Tuning knobs (`maxFrames`, `minScore`, `cols`, `scrollbar`) are static constants at the top of the file.
- **`icon.swift`**: a standalone script (`swift icon.swift out.png`) that draws the 1024px icon. It isn't part of the app binary.

The README's "Known limits" section lists the full-page capture limits that are known and accepted. Read it before treating one of them as a bug.
