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
# CI (.github/workflows/deploy-prod.yml) runs it with these instead of the keychain:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   notarize with an app-specific password, not a saved profile
#   SPARKLE_PRIVATE_KEY_FILE                       the update key exported with generate_keys -x
#   SPARKLE_EXPECTED_PUBLIC_KEY                    optional: stop if the key file is not the one installed copies trust
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
if [[ -n "${APPLE_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --team-id "${APPLE_TEAM_ID:?APPLE_TEAM_ID is needed with APPLE_ID}" \
        --password "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is needed with APPLE_ID}")
else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi
if ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
    if [[ -n "${APPLE_ID:-}" ]]; then
        echo "Apple refused the notarization login for $APPLE_ID (check APPLE_TEAM_ID and the app-specific password)." >&2
        exit 1
    fi
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
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    # An exported key is base64 of 64 bytes (seed + public key) or 96 bytes (older format: seed, public key,
    # public key). Either way bytes 33 to 64 are the public key.
    PUBLIC_KEY="$(tr -d ' \n\r' < "$SPARKLE_PRIVATE_KEY_FILE" | base64 -D | tail -c +33 | head -c 32 | base64)"
    SIGN_KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
else
    # generate_keys -p prints an error on stdout and fails when there is no key yet, so trust only its success.
    PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" || PUBLIC_KEY=""
    if [[ -z "$PUBLIC_KEY" ]]; then
        echo "Creating the update signing key in your login keychain…"
        "$SPARKLE_BIN/generate_keys" >/dev/null
        PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
    fi
    SIGN_KEY_ARGS=()
fi
# An EdDSA public key is 32 bytes, 44 characters of base64.
if [[ ! "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Could not read the update signing key (got: $PUBLIC_KEY)." >&2
    exit 1
fi
if [[ -n "${SPARKLE_EXPECTED_PUBLIC_KEY:-}" && "$PUBLIC_KEY" != "$SPARKLE_EXPECTED_PUBLIC_KEY" ]]; then
    echo "The update key's public part is $PUBLIC_KEY, but installed copies trust $SPARKLE_EXPECTED_PUBLIC_KEY." >&2
    exit 1
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" SIGN_IDENTITY="$IDENTITY" SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" \
    ./scripts/build-app.sh

APP="build/RoomyDisk.app"
echo "Sending to Apple for notarization (usually a few minutes)…"
rm -f build/notarize.zip
ditto -c -k --keepParent "$APP" build/notarize.zip
xcrun notarytool submit build/notarize.zip "${NOTARY_AUTH[@]}" --wait
rm -f build/notarize.zip
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ZIP="build/RoomyDisk-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "RoomyDisk-$VERSION.zip" > "RoomyDisk-$VERSION.zip.sha256")

# One-item feed: installed copies only need the newest version. It is uploaded with each release,
# and Info.plist's SUFeedURL points at the latest release's copy.
SIGNATURE="$("$SPARKLE_BIN/sign_update" ${SIGN_KEY_ARGS[@]+"${SIGN_KEY_ARGS[@]}"} "$ZIP")"
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
