#!/usr/bin/env bash
# Packages build/EasyScreen.app into build/EasyScreen-<version>-arm64.dmg with
# an /Applications shortcut for drag-and-drop install.
#
# Environment:
#   VERSION        used in the file name (default: 0.0.0-dev)
#   SIGN_IDENTITY  when set (and not "-"), the DMG is signed too
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.0.0-dev}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/EasyScreen.app"
DMG="build/EasyScreen-${VERSION}-arm64.dmg"
VOLNAME="EasyScreen ${VERSION}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found; run scripts/build-app.sh first" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
RW_DMG="$(mktemp -u).dmg"
MOUNT_DIR=""
cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then hdiutil detach "$MOUNT_DIR" -quiet || true; fi
  rm -rf "$STAGE" "$RW_DMG"
}
trap cleanup EXIT

# hdiutil occasionally fails with "Resource busy" on CI runners; retry.
retry() {
  local attempt
  for attempt in 1 2 3 4; do
    if "$@"; then return 0; fi
    echo "warning: '$1 $2' failed (attempt $attempt), retrying…" >&2
    sleep $((attempt * 2))
  done
  "$@"
}

echo "==> Staging"
ditto "$APP" "$STAGE/EasyScreen.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

echo "==> Creating disk image"
retry hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW_DMG"

# Give the mounted volume the app icon (best effort; needs SetFile).
MOUNT_DIR="$(mktemp -d)"
retry hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT_DIR" "$RW_DMG"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT_DIR" || true
elif xcrun --find SetFile >/dev/null 2>&1; then
  "$(xcrun --find SetFile)" -a C "$MOUNT_DIR" || true
fi
sync
retry hdiutil detach -quiet "$MOUNT_DIR"
MOUNT_DIR=""

rm -f "$DMG"
retry hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "==> Signing DMG"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

hdiutil verify -quiet "$DMG"
shasum -a 256 "$DMG" | sed "s#build/##" > "$DMG.sha256"
echo "==> Built $DMG"
cat "$DMG.sha256"
