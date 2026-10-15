#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -parse-as-library \
 app/Sources/Engine.swift app/Sources/Native*.swift scripts/NativeCLI.swift \
 -o build/session-share
printf 'Built build/session-share\n'
