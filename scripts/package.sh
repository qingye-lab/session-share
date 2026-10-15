#!/bin/sh
# Build matching ZIP/DMG payloads with first-open instructions.
set -eu
cd "$(dirname "$0")/.."
./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'dist/会话合并.app/Contents/Info.plist')
name="Session-Share-${version}-macOS-arm64"
codesign --verify --deep --strict 'dist/会话合并.app'
stage=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto 'dist/会话合并.app' "$stage/会话合并.app"
cp 'packaging/首次打开方法.txt' "$stage/首次打开方法.txt"
# ZIP includes the app and instructions at its root; the installer shortcut
# is added afterwards so it only appears in the DMG.
ditto -c -k --sequesterRsrc "$stage" "dist/${name}.zip"
ln -s /Applications "$stage/Applications"
hdiutil create -volname 'Session Share' -srcfolder "$stage" -ov -format UDZO "dist/${name}.dmg"
(cd dist && shasum -a 256 "${name}.dmg" "${name}.zip" > SHA256SUMS.txt)
printf 'Packaged: dist/%s.{dmg,zip}\n' "$name"
