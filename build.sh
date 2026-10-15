#!/bin/sh
# Builds dist/会话合并.app: the menu bar app, with run.sh, cli.mjs and core.mjs
# inside it, so it works without this folder (or this drive).
set -e
cd "$(dirname "$0")"
app="dist/会话合并.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  app/Sources/*.swift -o "$app/Contents/MacOS/SessionMerge"
cp app/Info.plist "$app/Contents/"
cp app/run.sh cli.mjs core.mjs "$app/Contents/Resources/"
if [ ! -f build/AppIcon.icns ] || [ app/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift app/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/"
codesign --force --deep -s - "$app"
echo "built $app"
