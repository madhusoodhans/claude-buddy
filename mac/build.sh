#!/usr/bin/env bash
# Builds "Claude Buddy.app" (universal: Apple silicon + Intel, macOS 12+) and a zip to copy to other Macs.
#   ./build.sh        -> dist/Claude Buddy.app, dist/ClaudeBuddy-mac.zip
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Claude Buddy.app"
rm -rf dist build && mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos12.0" ClaudeBuddy.swift -o "build/ClaudeBuddy-$arch"
done
lipo -create build/ClaudeBuddy-arm64 build/ClaudeBuddy-x86_64 -output "$APP/Contents/MacOS/ClaudeBuddy"
cp ../remote/buddy-agent.py "$APP/Contents/Resources/"  # sent to remote machines over SSH

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Buddy</string>
  <key>CFBundleDisplayName</key><string>Claude Buddy</string>
  <key>CFBundleIdentifier</key><string>com.diypet.claudebuddy</string>
  <key>CFBundleExecutable</key><string>ClaudeBuddy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Claude Buddy talks to your Claude Buddy desk gadget over Bluetooth.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd dist && ditto -c -k --keepParent "Claude Buddy.app" ClaudeBuddy-mac.zip)
rm -rf build
echo "built $APP and dist/ClaudeBuddy-mac.zip"
