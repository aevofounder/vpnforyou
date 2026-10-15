#!/bin/bash
# Packs VPNforYou.app into a compressed .dmg with an Applications link,
# verifies it and writes a .sha256 file next to it.
#
#   scripts/make-dmg.sh path/to/VPNforYou.app 0.2.0 dist
set -euo pipefail

APP="$1"
VERSION="$2"
OUT="$3"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "bad version: $VERSION" >&2; exit 1; }
[[ -d "$APP" ]] || { echo "no app at $APP" >&2; exit 1; }

STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE" "$OUT"
ditto "$APP" "$STAGE/VPNforYou.app"
ln -s /Applications "$STAGE/Applications"

NAME="VPNforYou-$VERSION.dmg"
hdiutil create -volname "VPNforYou $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME"
# hdiutil create can return while diskimages-helper still holds the file
# ("Resource temporarily unavailable"): give verify a few tries.
for attempt in 1 2 3 4 5; do
  if hdiutil verify "$OUT/$NAME"; then break; fi
  [[ "$attempt" == 5 ]] && { echo "dmg verify failed" >&2; exit 1; }
  sleep 3
done
rm -rf "$STAGE"

(cd "$OUT" && shasum -a 256 "$NAME" | tee "$NAME.sha256")
