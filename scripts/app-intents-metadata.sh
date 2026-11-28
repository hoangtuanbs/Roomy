#!/bin/bash
# Makes the metadata Shortcuts reads to find RoomyDisk's actions (Contents/Resources/Metadata.appintents). Xcode does
# this step itself; a SwiftPM build does not, so build-app.sh calls this. It never fails the build: without the
# metadata the app works the same, its actions just don't show in Shortcuts.
# Usage: scripts/app-intents-metadata.sh <swift build bin dir> <RoomyDisk.app>
set -uo pipefail
BIN_DIR="$1"
APP="$2"
PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)" || { echo "app intents: no metadata processor"; exit 0; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")"
XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')"
ARCH="$(uname -m)"
find "$(pwd)/Sources/Roomy" -name '*.swift' > "$WORK/sources.txt"
find "$BIN_DIR/Roomy.build" "$BIN_DIR" -maxdepth 2 -name '*.swiftconstvalues' 2>/dev/null | sort -u > "$WORK/constvalues.txt"
: > "$WORK/metadata.txt"
: > "$WORK/static-metadata.txt"
echo "app intents: $(wc -l < "$WORK/constvalues.txt" | tr -d ' ') const value files, Xcode ${XCODE_BUILD:-?}"
"$PROCESSOR" \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name Roomy \
    --sdk-root "$SDK" \
    --xcode-version "${XCODE_BUILD:-17A1}" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --bundle-identifier io.github.hoangtuanbs.Roomy \
    --output "$APP/Contents/Resources" \
    --target-triple "$ARCH-apple-macos14.0" \
    --binary-file "$APP/Contents/MacOS/RoomyDisk" \
    --dependency-file "$WORK/deps" \
    --stringsdata-file "$WORK/ExtractedAppShortcutsMetadata.stringsdata" \
    --source-file-list "$WORK/sources.txt" \
    --metadata-file-list "$WORK/metadata.txt" \
    --static-metadata-file-list "$WORK/static-metadata.txt" \
    --swift-const-vals-list "$WORK/constvalues.txt" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --force > "$WORK/log.txt" 2>&1
status=$?
tail -20 "$WORK/log.txt"
head -3 "$WORK/constvalues.txt"
if [[ -d "$APP/Contents/Resources/Metadata.appintents" ]]; then
    echo "app intents: made Metadata.appintents: $(ls "$APP/Contents/Resources/Metadata.appintents" | tr '\n' ' ')"
    grep -o '"identifier" *: *"[A-Za-z]*Intent"' "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" 2>/dev/null | sort -u
else
    echo "app intents: no metadata was made (status $status)"
fi
exit 0
