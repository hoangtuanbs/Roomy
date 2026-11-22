#!/bin/bash
# Builds a signed, notarized RoomyDisk and the update feed that installed copies read.
#
#   ./scripts/release.sh 1.0.0             # build, sign, notarize and staple into build/
#   ./scripts/release.sh 1.0.0 --publish   # same, then publish GitHub release v1.0.0 with the feed
#
# Needs, on this Mac:
#   - a "Developer ID Application" certificate in the keychain (Xcode › Settings › Accounts › Manage Certificates)
#   - notarization login saved once: xcrun notarytool store-credentials roomydisk --apple-id … --team-id …
#   - for --publish: the GitHub CLI (gh), signed in
# The Sparkle update key is created in the login keychain on first run. Keep it: every future update
# must be signed with the same key, or installed copies will refuse it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 X.Y.Z [--publish]" >&2
    exit 1
fi
TAG="v$VERSION"
NOTARY_PROFILE="${NOTARY_PROFILE:-roomydisk}"
REPO="hoangtuanbs/Roomy"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
if [[ -z "$IDENTITY" ]]; then
    echo "No Developer ID Application certificate found. Create one in Xcode › Settings › Accounts › Manage Certificates." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarization login saved as \"$NOTARY_PROFILE\". Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id <TEAMID>" >&2
    exit 1
fi
if [[ "$PUBLISH" == "--publish" ]] && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists." >&2
    exit 1
fi
echo "Signing as: $IDENTITY"

swift package resolve
SPARKLE_BIN="$(dirname "$(find .build/artifacts -type f -name generate_keys -path '*/bin/*' | head -n 1)")"
# generate_keys -p prints an error on stdout and fails when there is no key yet, so trust only its success.
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" || PUBLIC_KEY=""
if [[ -z "$PUBLIC_KEY" ]]; then
    echo "Creating the update signing key in your login keychain…"
    "$SPARKLE_BIN/generate_keys" >/dev/null
    PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
fi
# An EdDSA public key is 32 bytes, 44 characters of base64.
if [[ ! "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Could not read the update signing key (got: $PUBLIC_KEY)." >&2
    exit 1
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" SIGN_IDENTITY="$IDENTITY" SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" \
    ./scripts/build-app.sh

APP="build/RoomyDisk.app"
echo "Sending to Apple for notarization (usually a few minutes)…"
rm -f build/notarize.zip
ditto -c -k --keepParent "$APP" build/notarize.zip
xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
rm -f build/notarize.zip
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ZIP="build/RoomyDisk-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "RoomyDisk-$VERSION.zip" > "RoomyDisk-$VERSION.zip.sha256")

# One-item feed: installed copies only need the newest version. It is uploaded with each release,
# and Info.plist's SUFeedURL points at the latest release's copy.
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP")"
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>RoomyDisk</title>
    <item>
      <title>RoomyDisk $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/RoomyDisk-$VERSION.zip" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
echo "Built $ZIP, signed, notarized and stapled, with build/appcast.xml"

if [[ "$PUBLISH" == "--publish" ]]; then
    cat > build/notes.md <<NOTES
Download **RoomyDisk-$VERSION.zip**, unzip it and move **RoomyDisk.app** to Applications.
This version is signed and notarized by Apple. Installed copies update themselves.
Requires macOS 14 or later.
NOTES
    gh release create "$TAG" "$ZIP" "$ZIP.sha256" build/appcast.xml \
        --repo "$REPO" \
        --title "RoomyDisk $VERSION" \
        --target "$(git rev-parse HEAD)" \
        --notes-file build/notes.md \
        --generate-notes
    echo "Published https://github.com/$REPO/releases/tag/$TAG"
fi
