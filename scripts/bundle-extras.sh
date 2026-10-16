#!/bin/bash
# Adds the privileged helper and the mihomo core to a built VPNforYou.app
# and re-signs it ad hoc. Used by CI; works locally on a Mac with Xcode.
#
#   scripts/bundle-extras.sh path/to/VPNforYou.app
#
# mihomo is the official release build, pinned by version and SHA-256
# (the release has no checksum file; the hashes were recorded on first download).
set -euo pipefail

APP="$1"
MIHOMO_VERSION="v1.19.32"
MIHOMO_ARM64_SHA256="3312a6780652c622890fd4357c6a853bbf865464fd047ac7b7f52dab8de18652"
MIHOMO_AMD64_SHA256="18b382df77bded2ad0fb3db27db5636cb15b20729d5ba995a357eeb9b46bf507"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-$(mktemp -d)}/vpnforyou-extras"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== helper (arm64 + x86_64)"
swift build -c release --package-path "$ROOT/Packages/VPNCore" --product vpnforyou-helper --arch arm64 --arch x86_64
HELPER_DIR="$(swift build -c release --package-path "$ROOT/Packages/VPNCore" --product vpnforyou-helper --arch arm64 --arch x86_64 --show-bin-path)"

echo "== mihomo $MIHOMO_VERSION"
fetch() {
  local name="$1" sum="$2"
  curl -sSfL -o "$WORK/$name.gz" "https://github.com/MetaCubeX/mihomo/releases/download/$MIHOMO_VERSION/$name.gz"
  echo "$sum  $WORK/$name.gz" | shasum -a 256 -c -
  gunzip -f "$WORK/$name.gz"
}
fetch "mihomo-darwin-arm64-$MIHOMO_VERSION" "$MIHOMO_ARM64_SHA256"
fetch "mihomo-darwin-amd64-compatible-$MIHOMO_VERSION" "$MIHOMO_AMD64_SHA256"
lipo -create -output "$WORK/mihomo" \
  "$WORK/mihomo-darwin-arm64-$MIHOMO_VERSION" \
  "$WORK/mihomo-darwin-amd64-compatible-$MIHOMO_VERSION"

echo "== bundle and sign"
install -m 755 "$HELPER_DIR/vpnforyou-helper" "$APP/Contents/MacOS/vpnforyou-helper"
install -m 755 "$WORK/mihomo" "$APP/Contents/MacOS/mihomo"
codesign --force --sign - "$APP/Contents/MacOS/vpnforyou-helper"
codesign --force --sign - "$APP/Contents/MacOS/mihomo"
codesign --force --sign - "$APP"
lipo -info "$APP/Contents/MacOS/vpnforyou-helper" "$APP/Contents/MacOS/mihomo"
