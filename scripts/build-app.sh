#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/RoomyDisk.app"
swift build -c release --product Roomy
BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Roomy" "$APP/Contents/MacOS/RoomyDisk"
# Sparkle (automatic updates) ships inside the app; ditto keeps the framework's symlinks.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/RoomyDisk" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/RoomyDisk"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Translations: one <lang>.lproj folder per language, read by SwiftUI and AppKit from the main bundle.
for lproj in Localization/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The Shortcuts actions' metadata, which Xcode would make; never fails the build.
./scripts/app-intents-metadata.sh "$BIN_DIR" "$APP"
# Optional version stamping, used by the release workflow: VERSION=1.2.3 BUILD_NUMBER=42 ./scripts/build-app.sh
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
# The update key is added only by scripts/release.sh; without it the app never looks for updates.
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi
# Signing: ad hoc by default (local use only). SIGN_IDENTITY="Developer ID Application: …" signs for
# distribution with the hardened runtime, inside out as Sparkle's documentation describes.
IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign - --identifier io.github.hoangtuanbs.Roomy "$APP"
else
    SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    [[ -d "$FW/Versions/B/XPCServices/Installer.xpc" ]] && "${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
    [[ -d "$FW/Versions/B/XPCServices/Downloader.xpc" ]] && \
        "${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
    "${SIGN[@]}" "$FW/Versions/B/Autoupdate"
    "${SIGN[@]}" "$FW/Versions/B/Updater.app"
    "${SIGN[@]}" "$FW"
    "${SIGN[@]}" --identifier io.github.hoangtuanbs.Roomy "$APP"
fi
codesign --verify --deep --strict "$APP"
touch "$APP"
rm -f build/RoomyDisk.zip
ditto -c -k --keepParent "$APP" build/RoomyDisk.zip
echo "Built $APP and build/RoomyDisk.zip"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/RoomyDisk.app
    cp -R "$APP" /Applications/RoomyDisk.app
fi
