#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/RoomyDisk.app"
swift build -c release --product Roomy
BIN="$(swift build -c release --show-bin-path)/Roomy"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RoomyDisk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Translations: one <lang>.lproj folder per language, read by SwiftUI and AppKit from the main bundle.
for lproj in Localization/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Optional version stamping, used by the release workflow: VERSION=1.2.3 BUILD_NUMBER=42 ./scripts/build-app.sh
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
codesign --force --sign - --identifier io.github.hoangtuanbs.Roomy "$APP"
touch "$APP"
rm -f build/RoomyDisk.zip
ditto -c -k --keepParent "$APP" build/RoomyDisk.zip
echo "Built $APP and build/RoomyDisk.zip"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/RoomyDisk.app
    cp -R "$APP" /Applications/RoomyDisk.app
fi
