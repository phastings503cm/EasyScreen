#!/usr/bin/env bash
# Builds build/EasyScreen.app (Apple Silicon / arm64 only).
#
# Environment:
#   VERSION        marketing version (default: 0.0.0-dev)
#   BUILD_NUMBER   CFBundleVersion  (default: 1)
#   SIGN_IDENTITY  codesigning identity (name or SHA-1); ad-hoc ("-") when unset
#   BUNDLE_ID      bundle identifier. Defaults to the release ID for signed
#                  builds and to "<release ID>.dev" ("EasyScreen Dev") for
#                  ad-hoc builds, so local builds never take over the Screen
#                  Recording permission macOS has stored for the release app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
RELEASE_BUNDLE_ID="io.github.phastings503cm.EasyScreen"
if [[ -z "${BUNDLE_ID:-}" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then BUNDLE_ID="$RELEASE_BUNDLE_ID.dev"; else BUNDLE_ID="$RELEASE_BUNDLE_ID"; fi
fi
APP_NAME="EasyScreen"
[[ "$BUNDLE_ID" != "$RELEASE_BUNDLE_ID" ]] && APP_NAME="EasyScreen Dev"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/EasyScreen.app"

echo "==> Compiling EasyScreen $VERSION ($BUILD_NUMBER) for arm64"
swift build -c release --arch arm64 --product EasyScreen
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EasyScreen" "$APP/Contents/MacOS/EasyScreen"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__APP_NAME__/$APP_NAME/g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ARCHS="$(lipo -archs "$APP/Contents/MacOS/EasyScreen")"
if [[ "$ARCHS" != "arm64" ]]; then
  echo "error: expected an arm64-only binary, got: $ARCHS" >&2
  exit 1
fi

echo "==> Signing $BUNDLE_ID with identity: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
elif [[ "$SIGN_IDENTITY" == *"Developer ID"* ]]; then
  # Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  # Self-signed identity: gives every release the same designated
  # requirement, so macOS keeps Screen Recording permission across updates.
  codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
fi
echo "    $(codesign -d -r- "$APP" 2>&1 | grep designated)"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Built $APP"
