#!/bin/sh
# Builds the native Swift menu bar app. No third-party runtime is bundled.
set -eu
cd "$(dirname "$0")"
app="dist/会话合并.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  app/Sources/*.swift -o "$app/Contents/MacOS/SessionMerge"
cp app/Info.plist "$app/Contents/"
if [ ! -f build/AppIcon.icns ] || [ app/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift app/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/"
codesign --force --deep -s - "$app"
echo "built $app"
