#!/bin/zsh
# Builds Satsuma.app and installs it into ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Satsuma.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Satsuma "$APP/Contents/MacOS/Satsuma"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.satsuma</string>
  <key>CFBundleName</key><string>Satsuma</string>
  <key>CFBundleExecutable</key><string>Satsuma</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Satsuma reads your Finder selection when you press the wheel hotkey.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/Satsuma.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Satsuma.app"
