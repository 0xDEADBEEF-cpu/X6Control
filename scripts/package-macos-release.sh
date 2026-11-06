#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
APP="$ROOT/dist/X6 Control.app"
OUT="$ROOT/dist"
STAGING="$ROOT/.build/dmg-staging"

if [[ ! -d "$APP" ]]; then
  echo "Build the app first: scripts/build-macos.sh universal" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 [MAJOR.MINOR.PATCH]" >&2
  exit 2
fi

ZIP="$OUT/X6-Control-macOS-universal-v$VERSION.zip"
DMG="$OUT/X6-Control-macOS-universal-v$VERSION.dmg"
rm -f "$ZIP" "$DMG" "$OUT/SHA256SUMS"
ditto -c -k --keepParent "$APP" "$ZIP"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/X6 Control.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "X6 Control $VERSION" -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS)
echo "Created $ZIP, $DMG, and $OUT/SHA256SUMS"
