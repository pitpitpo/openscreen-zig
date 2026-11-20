#!/usr/bin/env bash
set -euo pipefail

# Build OpenScreen macOS .app bundle and .dmg
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="OpenScreen.app"
APP_DIR="${DIST_DIR}/${APP_NAME}"
DMG_NAME="OpenScreen-macOS-universal.dmg"

echo "=== Building OpenScreen ReleaseFast Binary ==="
cd "${ROOT_DIR}"
zig build -Doptimize=ReleaseFast

echo "=== Creating macOS App Bundle ==="
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${ROOT_DIR}/zig-out/bin/openscreen" "${APP_DIR}/Contents/MacOS/openscreen"
chmod +x "${APP_DIR}/Contents/MacOS/openscreen"

cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Contents/Info.plist"

# Copy assets & notices
mkdir -p "${APP_DIR}/Contents/Resources/assets"
cp -r "${ROOT_DIR}/assets/"* "${APP_DIR}/Contents/Resources/assets/"
cp "${ROOT_DIR}/LICENSE" "${APP_DIR}/Contents/Resources/LICENSE"
cp "${ROOT_DIR}/THIRD-PARTY-NOTICES.md" "${APP_DIR}/Contents/Resources/THIRD-PARTY-NOTICES.md"

if [ -f "${ROOT_DIR}/assets/openscreen.icns" ]; then
    cp "${ROOT_DIR}/assets/openscreen.icns" "${APP_DIR}/Contents/Resources/openscreen.icns"
fi

# Code Signing (ad-hoc if no identity specified)
SIGN_IDENTITY="${APPLE_SIGNING_IDENTITY:--}"
echo "=== Signing App Bundle (${SIGN_IDENTITY}) ==="
codesign --force --options runtime --deep --entitlements "${SCRIPT_DIR}/macos.entitlements" --sign "${SIGN_IDENTITY}" "${APP_DIR}"

# Create DMG
if command -v hdiutil &>/dev/null; then
    echo "=== Creating DMG Archive ==="
    mkdir -p "${DIST_DIR}"
    rm -f "${DIST_DIR}/${DMG_NAME}"
    hdiutil create -volname "OpenScreen" -srcfolder "${APP_DIR}" -ov -format UDZO "${DIST_DIR}/${DMG_NAME}"
    echo "Successfully generated: ${DIST_DIR}/${DMG_NAME}"
else
    echo "hdiutil not available (not macOS host). App bundle created at ${APP_DIR}"
fi
