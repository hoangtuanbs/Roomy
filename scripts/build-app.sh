#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Roomy.app"
swift build -c release --product Roomy
BIN="$(swift build -c release --show-bin-path)/Roomy"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Roomy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
rm -f build/Roomy.zip
ditto -c -k --keepParent "$APP" build/Roomy.zip
echo "Built $APP and build/Roomy.zip"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Roomy.app
    cp -R "$APP" /Applications/Roomy.app
fi
