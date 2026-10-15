#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 -parse-as-library \
 app/Sources/Engine.swift app/Sources/Native*.swift scripts/DemoData.swift \
 -o build/demo-data
build/demo-data "$@"
