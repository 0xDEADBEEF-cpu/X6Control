#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-native}"
VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must use MAJOR.MINOR.PATCH" >&2
  exit 2
fi

case "$MODE" in
  native)
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
      arm64|aarch64) ARCHES=(arm64) ;;
      x86_64) ARCHES=(x86_64) ;;
      *) echo "Unsupported build architecture: $HOST_ARCH" >&2; exit 2 ;;
    esac
    ;;
  universal) ARCHES=(arm64 x86_64) ;;
  arm64|x86_64) ARCHES=("$MODE") ;;
  *) echo "Usage: $0 [native|universal|arm64|x86_64]" >&2; exit 2 ;;
esac

MINIMUM_MACOS="13.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_DIR="$ROOT/.build/macos"
APP="$ROOT/dist/X6 Control.app"
IDENTITY="${SIGNING_IDENTITY:--}"
rm -rf "$BUILD_DIR" "$ROOT/dist"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in "${ARCHES[@]}"; do
  TARGET="$ARCH-apple-macosx$MINIMUM_MACOS"
  swiftc -O -parse-as-library -target "$TARGET" -sdk "$SDK" \
    "$ROOT/app/X6ControlApp.swift" -framework AppKit -framework WebKit \
    -o "$BUILD_DIR/X6Control-$ARCH"
  swiftc -O -target "$TARGET" -sdk "$SDK" \
    "$ROOT/bridge/X6Bridge.swift" -framework IOKit \
    -o "$BUILD_DIR/X6Bridge-$ARCH"
done

if (( ${#ARCHES[@]} == 1 )); then
  cp "$BUILD_DIR/X6Control-${ARCHES[0]}" "$APP/Contents/MacOS/X6Control"
  cp "$BUILD_DIR/X6Bridge-${ARCHES[0]}" "$APP/Contents/Resources/X6Bridge"
else
  lipo -create "$BUILD_DIR/X6Control-arm64" "$BUILD_DIR/X6Control-x86_64" \
    -output "$APP/Contents/MacOS/X6Control"
  lipo -create "$BUILD_DIR/X6Bridge-arm64" "$BUILD_DIR/X6Bridge-x86_64" \
    -output "$APP/Contents/Resources/X6Bridge"
fi

cp -R "$ROOT/public" "$APP/Contents/Resources/public"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/packaging/Info.plist.in" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/X6Control" "$APP/Contents/Resources/X6Bridge"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/Resources/X6Bridge"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/X6Bridge"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi

plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($MODE, macOS $MINIMUM_MACOS+, version $VERSION)"
if [[ "$IDENTITY" == "-" ]]; then
  echo "Ad-hoc signed. Set SIGNING_IDENTITY to a Developer ID Application identity for distribution signing."
fi
