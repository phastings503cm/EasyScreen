#!/usr/bin/env bash
# Builds build/EasyScreen.app (Apple Silicon / arm64 only).
#
# Environment:
#   VERSION        marketing version (default: 0.0.0-dev)
#   BUILD_NUMBER   CFBundleVersion  (default: 1)
#   SIGN_IDENTITY  codesigning identity; ad-hoc ("-") when unset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/EasyScreen.app"

echo "==> Compiling EasyScreen $VERSION ($BUILD_NUMBER) for arm64"
swift build -c release --arch arm64 --product EasyScreen
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EasyScreen" "$APP/Contents/MacOS/EasyScreen"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ARCHS="$(lipo -archs "$APP/Contents/MacOS/EasyScreen")"
if [[ "$ARCHS" != "arm64" ]]; then
  echo "error: expected an arm64-only binary, got: $ARCHS" >&2
  exit 1
fi

echo "==> Signing with identity: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier io.github.phastings503cm.EasyScreen "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "==> Built $APP"
