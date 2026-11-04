#!/bin/sh
# Builds YKShot.app and installs it to /Applications. Run: ./build.sh   (./build.sh icon also redraws AppIcon.icns)
set -e
cd "$(dirname "$0")"
NAME=YKShot
VERSION=1.0.0
APP=$NAME.app

if [ "$1" = icon ] || [ ! -f AppIcon.icns ]; then
  T=$(mktemp -d); mkdir "$T/AppIcon.iconset"
  swift icon.swift "$T/1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$T/1024.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$T/1024.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$T/AppIcon.iconset" -o AppIcon.icns
  rm -rf "$T"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
swiftc -O main.swift PageCapture.swift -o "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.ykshot</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# Stable identity (bundle id, not per-build hash) so macOS permissions survive rebuilds.
codesign -s - --force -r='designated => identifier "local.ykshot"' "$APP"

# Install: stop our running copy (matched by path, so other apps are left alone), replace, relaunch.
pkill -f "^/Applications/$APP/Contents/MacOS/" || true
pkill -f "^$PWD/$APP/Contents/MacOS/" || true
while pgrep -f "$APP/Contents/MacOS/" >/dev/null; do sleep 0.1; done   # relaunching too early fails with error -600
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/
# Make Finder/Launchpad pick up icon changes instead of a cached copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP"
open "/Applications/$APP"
echo "Installed /Applications/$APP"
