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
codesign --force --sign - --identifier io.github.hoangtuanbs.Roomy "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Roomy.app
    cp -R "$APP" /Applications/Roomy.app
fi
