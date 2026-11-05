#!/bin/zsh
set -eu
cd "$(dirname "$0")"
stage=$(mktemp -d "${TMPDIR:-/tmp/}HarmonyBridge-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/HarmonyBridge.app/Contents/MacOS" "$stage/HarmonyBridge.app/Contents/Resources"
cp HarmonyBridge.app/Contents/Info.plist "$stage/HarmonyBridge.app/Contents/Info.plist"
cp Assets/Bridge.icns "$stage/HarmonyBridge.app/Contents/Resources/Bridge.icns"
swiftc -parse-as-library -swift-version 5 -O -framework AppKit -framework SwiftUI -framework VideoToolbox -framework AVFoundation -framework Network Sources/*.swift -o "$stage/HarmonyBridge.app/Contents/MacOS/HarmonyBridge"
xattr -cr "$stage/HarmonyBridge.app"
codesign --force --sign - "$stage/HarmonyBridge.app"
ditto --noextattr --norsrc "$stage/HarmonyBridge.app" HarmonyBridge.app
codesign --verify HarmonyBridge.app
echo "Built HarmonyBridge.app"
