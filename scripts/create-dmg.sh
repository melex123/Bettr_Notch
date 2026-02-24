#!/bin/bash
set -euo pipefail

APP_BUNDLE="${1:?Usage: create-dmg.sh <app> <output.dmg> <name> <staging_dir> <identity>}"
DMG_OUTPUT="${2}"
APP_NAME="${3}"
STAGING_DIR="${4}"
SIGNING_IDENTITY="${5:--}"

echo "Creating DMG: $DMG_OUTPUT"

# Clean staging area
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app bundle into staging
cp -R "$APP_BUNDLE" "$STAGING_DIR/"

# Create Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

# Remove any existing DMG
rm -f "$DMG_OUTPUT"

# Create DMG
#   -volname: Volume name shown in Finder
#   -srcfolder: Source folder to pack
#   -ov: Overwrite existing
#   -format UDZO: Compressed, read-only (standard for distribution)
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

# Sign DMG if not ad-hoc
if [ "$SIGNING_IDENTITY" != "-" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$DMG_OUTPUT"
    echo "DMG signed."
fi

# Cleanup staging
rm -rf "$STAGING_DIR"

echo "DMG created: $DMG_OUTPUT"
echo "Size: $(du -h "$DMG_OUTPUT" | cut -f1)"
