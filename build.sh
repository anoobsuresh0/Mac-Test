#!/bin/bash
# Builds MacCheck.app and MacCheck.dmg into ./dist.  Needs only Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP=dist/MacCheck.app
VERSION=${VERSION:-1.1}   # the release workflow sets this from the git tag (v1.2 -> 1.2)
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# macOS 12 target so it runs on used Macs that were never updated
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos12.0 MacCheck.swift -o "$APP/Contents/MacOS/MacCheck"
clang -O2 -mmacosx-version-min=12.0 ssdwear.c -framework IOKit -framework CoreFoundation -o "$APP/Contents/MacOS/ssdwear"
cp mac-check.sh test-page.html AppIcon.icns "$APP/Contents/Resources/"   # AppIcon.icns comes from: swift make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacCheck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.maccheck</string>
  <key>CFBundleName</key><string>Mac Check</string>
  <key>CFBundleDisplayName</key><string>Mac Check</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Mac Check scans for nearby Bluetooth devices to test that this Mac's Bluetooth antenna works.</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# ad-hoc signature: required for arm64 binaries to launch at all (not a Developer ID)
codesign --force --deep -s - "$APP"

mkdir dist/dmg && cp -R "$APP" dist/dmg/ && ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname "Mac Check" -srcfolder dist/dmg -format UDZO -ov dist/MacCheck.dmg
rm -rf dist/dmg
echo "Built: dist/MacCheck.app and dist/MacCheck.dmg"
