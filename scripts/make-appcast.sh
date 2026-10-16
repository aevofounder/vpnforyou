#!/bin/bash
# Writes the Sparkle appcast for one signed build of the beta channel.
#
#   scripts/make-appcast.sh dist/VPNforYou.zip 'sparkle:edSignature="…" length="…"' owner/repo dist
#
# Output: <out>/VPNforYou-<build>.zip and <out>/appcast.xml, pointing to
# https://github.com/<repo>/releases/download/beta/VPNforYou-<build>.zip
set -euo pipefail

ZIP="$1"
SIGNATURE="$2"
REPO="$3"
OUT="$4"

[[ "$SIGNATURE" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]] \
  || { echo "unexpected sign_update output: $SIGNATURE" >&2; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "bad repo: $REPO" >&2; exit 1; }

WORK="$(mktemp -d)"
ditto -x -k "$ZIP" "$WORK"
PLIST="$WORK/VPNforYou.app/Contents/Info.plist"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
SHORT="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
MIN_OS="$(plutil -extract LSMinimumSystemVersion raw "$PLIST" 2>/dev/null || echo 14.0)"
rm -rf "$WORK"
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "bad build number: $BUILD" >&2; exit 1; }

NAME="VPNforYou-$BUILD.zip"
mkdir -p "$OUT"
cp "$ZIP" "$OUT/$NAME"

escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
WHEN="$(LC_ALL=C date -u -r "$BUILD" '+%d.%m.%Y %H:%M UTC')"
PUB_DATE="$(LC_ALL=C date -u -r "$BUILD" '+%a, %d %b %Y %H:%M:%S +0000')"
NOTES="$(git log -1 --format=%s 2>/dev/null | escape || true)"

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>VPNforYou — бета</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>$SHORT, сборка от $WHEN</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT бета ($WHEN)</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES</p>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/beta/$NAME" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
echo "appcast: build $BUILD → $NAME"
