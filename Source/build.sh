#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build ${SWIFT_BUILD_FLAGS:-} -c release --scratch-path .build
mkdir -p dist/d7n.app/Contents/MacOS
cp .build/release/d7n dist/d7n.app/Contents/MacOS/d7n
cp Info.plist dist/d7n.app/Contents/Info.plist
codesign --force --sign - dist/d7n.app
codesign --verify --strict dist/d7n.app
echo "Built dist/d7n.app"
