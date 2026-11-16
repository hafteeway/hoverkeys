#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/HoverKeys.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/module-cache
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
MACOSX_DEPLOYMENT_TARGET=14.0 xcrun swiftc -O -whole-module-optimization Sources/main.swift \
  -o "$app/Contents/MacOS/HoverKeys" \
  -framework AppKit -framework ApplicationServices -framework SwiftUI -framework ServiceManagement \
  -module-cache-path build/module-cache
xattr -cr "$app"
codesign --force --sign - --identifier app.hoverkeys.HoverKeys \
  -r='designated => identifier "app.hoverkeys.HoverKeys"' "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
