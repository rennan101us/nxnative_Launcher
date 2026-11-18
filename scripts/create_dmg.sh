#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_PATH="$ROOT_DIR/NxNative_Launcher.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH="$SCRIPT_DIR/../NxNative_Launcher.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: NxNative_Launcher.app not found. Build it first with build_gui.sh."
    exit 1
fi

DMG_NAME="NxNative_Launcher.dmg"
OUTPUT_DMG="$ROOT_DIR/$DMG_NAME"
STAGING="/tmp/nxnative_dmg_staging"

echo "==> Preparing DMG staging for NxNative_Launcher..."
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Copy App bundle without Finder detritus and ensure strict ad-hoc signature
cp -R -X "$APP_PATH" "$STAGING/" 2>/dev/null || cp -R "$APP_PATH" "$STAGING/"
STAGED_APP="$STAGING/$(basename "$APP_PATH")"
find "$STAGED_APP" \( -name ".DS_Store" -o -name "._*" -o -name $'Icon\r' \) -delete 2>/dev/null || true
xattr -cr "$STAGED_APP" 2>/dev/null || true
codesign --force --deep --sign - "$STAGED_APP"

# Create Applications shortcut
ln -s /Applications "$STAGING/Applications"

# Create DMG with maximum compression level
echo "==> Building compressed DMG: $OUTPUT_DMG"
rm -f "$OUTPUT_DMG"
hdiutil create -volname "NxNative_Launcher" -srcfolder "$STAGING" -ov -format UDZO -imagekey zlib-level=9 "$OUTPUT_DMG"

# Clean staging
rm -rf "$STAGING"

echo "==> Successfully created DMG at: $OUTPUT_DMG"
