#!/usr/bin/env bash
set -euo pipefail

# Build OpenScreen AppImage
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APPDIR="/tmp/OpenScreen.AppDir"

echo "=== Building OpenScreen ReleaseFast ==="
cd "${ROOT_DIR}"
zig build -Doptimize=ReleaseFast

echo "=== Creating AppDir Structure ==="
rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin"
mkdir -p "${APPDIR}/usr/share/applications"
mkdir -p "${APPDIR}/usr/share/icons/hicolor/512x512/apps"
mkdir -p "${APPDIR}/usr/share/openscreen"

cp "${ROOT_DIR}/zig-out/bin/openscreen" "${APPDIR}/usr/bin/openscreen"
chmod 755 "${APPDIR}/usr/bin/openscreen"

cp "${SCRIPT_DIR}/openscreen.desktop" "${APPDIR}/openscreen.desktop"
cp "${SCRIPT_DIR}/openscreen.desktop" "${APPDIR}/usr/share/applications/openscreen.desktop"
cp "${ROOT_DIR}/assets/openscreen.png" "${APPDIR}/openscreen.png"
cp "${ROOT_DIR}/assets/openscreen.png" "${APPDIR}/usr/share/icons/hicolor/512x512/apps/openscreen.png"

cp -r "${ROOT_DIR}/assets" "${APPDIR}/usr/share/openscreen/"
cp "${ROOT_DIR}/LICENSE" "${APPDIR}/LICENSE"
cp "${ROOT_DIR}/THIRD-PARTY-NOTICES.md" "${APPDIR}/THIRD-PARTY-NOTICES.md"

# Standard AppRun entrypoint
cat << 'EOF' > "${APPDIR}/AppRun"
#!/bin/sh
SELF=$(readlink -f "$0")
HERE=${SELF%/*}
export PATH="${HERE}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH:-}"
export OPENSCREEN_ASSETS="${HERE}/usr/share/openscreen/assets"
exec "${HERE}/usr/bin/openscreen" "$@"
EOF
chmod 755 "${APPDIR}/AppRun"

mkdir -p "${DIST_DIR}"

if command -v appimagetool &>/dev/null; then
    echo "=== Running appimagetool ==="
    appimagetool "${APPDIR}" "${DIST_DIR}/OpenScreen-x86_64.AppImage"
    echo "Successfully generated: ${DIST_DIR}/OpenScreen-x86_64.AppImage"
else
    echo "appimagetool not found; AppDir prepared at ${APPDIR}"
fi
