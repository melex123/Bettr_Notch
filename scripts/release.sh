#!/usr/bin/env bash
# release.sh — Create a GitHub Release and update appcast.xml
# Usage: release.sh <dmg-path> <version> <app-name>
set -euo pipefail

DMG_PATH="$1"
VERSION="$2"
APP_NAME="$3"

REPO="melex123/Bettr_Notch"
APPCAST="appcast.xml"
TAG="v${VERSION}"
DMG_FILENAME="$(basename "$DMG_PATH")"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_FILENAME}"

# --- Locate Sparkle sign_update tool ---
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -f "$SIGN_UPDATE" ]; then
    echo "Warning: sign_update not found at $SIGN_UPDATE"
    echo "Sparkle EdDSA signature will be skipped."
    echo "Run 'make generate-keys' first to set up signing."
    SPARKLE_SIG=""
else
    echo "Signing DMG with Sparkle EdDSA..."
    SPARKLE_SIG=$("$SIGN_UPDATE" "$DMG_PATH" 2>&1) || {
        echo "Warning: EdDSA signing failed. Continuing without signature."
        SPARKLE_SIG=""
    }
fi

# --- Get DMG file size ---
DMG_SIZE=$(stat -f%z "$DMG_PATH")
PUB_DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

echo ""
echo "=== Release Summary ==="
echo "  Version:  ${VERSION}"
echo "  Tag:      ${TAG}"
echo "  DMG:      ${DMG_PATH} (${DMG_SIZE} bytes)"
echo "  Download: ${DOWNLOAD_URL}"
if [ -n "$SPARKLE_SIG" ]; then
    echo "  Signature: (set)"
fi
echo ""

# --- Create GitHub Release ---
echo "Creating GitHub Release ${TAG}..."
if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
    echo "Release ${TAG} already exists. Uploading DMG..."
    gh release upload "$TAG" "$DMG_PATH" --repo "$REPO" --clobber
else
    gh release create "$TAG" "$DMG_PATH" \
        --repo "$REPO" \
        --title "${APP_NAME} ${VERSION}" \
        --notes "## ${APP_NAME} ${VERSION}

### What's New
- See commit history for changes

### Installation
1. Download **${DMG_FILENAME}**
2. Open the DMG and drag ${APP_NAME} to Applications
3. Existing users will be notified automatically via in-app updates" \
        --latest
fi
echo "GitHub Release created."

# --- Build Sparkle enclosure attributes ---
ENCLOSURE_ATTRS="url=\"${DOWNLOAD_URL}\" length=\"${DMG_SIZE}\" type=\"application/octet-stream\""
if [ -n "$SPARKLE_SIG" ]; then
    # sign_update outputs: sparkle:edSignature="..." length="..."
    # Extract just the signature value
    ED_SIG=$(echo "$SPARKLE_SIG" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
    if [ -n "$ED_SIG" ]; then
        ENCLOSURE_ATTRS="${ENCLOSURE_ATTRS} sparkle:edSignature=\"${ED_SIG}\""
    fi
fi

# --- Update appcast.xml ---
echo "Updating ${APPCAST}..."

NEW_ITEM="      <item>
        <title>${APP_NAME} ${VERSION}</title>
        <pubDate>${PUB_DATE}</pubDate>
        <sparkle:version>${VERSION}</sparkle:version>
        <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <enclosure ${ENCLOSURE_ATTRS} />
      </item>"

# Insert the new item before </channel>
if grep -q "<item>" "$APPCAST"; then
    # Appcast already has items — insert before the first <item>
    sed -i '' "/<item>/i\\
${NEW_ITEM}
" "$APPCAST"
else
    # Empty appcast — insert before </channel>
    sed -i '' "/<\/channel>/i\\
${NEW_ITEM}
" "$APPCAST"
fi

echo "Appcast updated with ${VERSION}."
echo ""
echo "Done! Next steps:"
echo "  1. Review appcast.xml changes"
echo "  2. Commit and push: git add appcast.xml && git commit -m 'Update appcast for ${VERSION}' && git push"
echo "  3. Verify the feed: https://raw.githubusercontent.com/${REPO}/main/appcast.xml"
