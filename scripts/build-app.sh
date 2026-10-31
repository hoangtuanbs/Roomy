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
codesign --force --sign - --identifier io.github.hoangtuanbs.Roomy "$APP"
touch "$APP"
ditto -c -k --keepParent "$APP" build/Roomy.zip
echo "Built $APP and build/Roomy.zip"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Roomy.app
    cp -R "$APP" /Applications/Roomy.app
fi
