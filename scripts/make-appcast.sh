#!/bin/bash
# Package a built LocalPort.app as a Sparkle update: build/LocalPort.zip and
# build/appcast.xml, the feed the app reads (SUFeedURL in Info.plist).
#
#   scripts/make-appcast.sh <version> [release-notes.md]
#
# Signs with the EdDSA key in $SPARKLE_PRIVATE_KEY (CI), else with the one in
# the login keychain (`generate_keys --account localport`). The key must match
# SUPublicEDKey, or apps will refuse the update.
#
# $SPARKLE_DOWNLOAD_BASE overrides where the zip is downloaded from (testing).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-appcast.sh <version> [release-notes.md]}"
NOTES="${2:-}"
APP="build/LocalPort.app"
ZIP="build/LocalPort.zip"
BIN="macos/.build/artifacts/sparkle/Sparkle/bin"
REPO_URL="https://github.com/HibiZA/LocalPort"
BASE_URL="${SPARKLE_DOWNLOAD_BASE:-$REPO_URL/releases/download/v$VERSION}"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    SIGNATURE=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - -p "$ZIP")
else
    SIGNATURE=$("$BIN/sign_update" --account localport -p "$ZIP")
fi

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
BUILD=$(plist CFBundleVersion)
MIN_OS=$(plist LSMinimumSystemVersion)
LENGTH=$(stat -f%z "$ZIP")
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

if [[ -n "$NOTES" && -s "$NOTES" ]]; then
    DESCRIPTION="<description sparkle:format=\"markdown\"><![CDATA[
$(cat "$NOTES")
]]></description>"
else
    DESCRIPTION="<description sparkle:format=\"markdown\"><![CDATA[
See the [release notes]($REPO_URL/releases/tag/v$VERSION) for what's new.
]]></description>"
fi

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LocalPort</title>
    <link>$REPO_URL</link>
    <item>
      <title>LocalPort $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      $DESCRIPTION
      <enclosure url="$BASE_URL/LocalPort.zip" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML

echo "  Built: $ZIP, build/appcast.xml"
