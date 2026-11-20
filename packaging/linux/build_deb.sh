#!/usr/bin/env bash
set -euo pipefail

# Build OpenScreen Debian package (.deb)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
PKG_VERSION="1.0.0"
ARCH="amd64"
PKG_NAME="openscreen_${PKG_VERSION}_${ARCH}"
BUILD_ROOT="/tmp/${PKG_NAME}"

echo "=== Building OpenScreen ReleaseFast ==="
cd "${ROOT_DIR}"
zig build -Doptimize=ReleaseFast

echo "=== Preparing Debian Package Tree ==="
rm -rf "${BUILD_ROOT}"
mkdir -p "${BUILD_ROOT}/DEBIAN"
mkdir -p "${BUILD_ROOT}/usr/bin"
mkdir -p "${BUILD_ROOT}/usr/share/applications"
mkdir -p "${BUILD_ROOT}/usr/share/icons/hicolor/512x512/apps"
mkdir -p "${BUILD_ROOT}/usr/share/openscreen"
mkdir -p "${BUILD_ROOT}/usr/share/doc/openscreen"

# Binary
cp "${ROOT_DIR}/zig-out/bin/openscreen" "${BUILD_ROOT}/usr/bin/openscreen"
chmod 755 "${BUILD_ROOT}/usr/bin/openscreen"

# Desktop integration & Icons
cp "${SCRIPT_DIR}/openscreen.desktop" "${BUILD_ROOT}/usr/share/applications/openscreen.desktop"
cp "${ROOT_DIR}/assets/openscreen.png" "${BUILD_ROOT}/usr/share/icons/hicolor/512x512/apps/openscreen.png"

# Assets and documentation
cp -r "${ROOT_DIR}/assets" "${BUILD_ROOT}/usr/share/openscreen/"
cp "${ROOT_DIR}/LICENSE" "${BUILD_ROOT}/usr/share/doc/openscreen/copyright"
cp "${ROOT_DIR}/THIRD-PARTY-NOTICES.md" "${BUILD_ROOT}/usr/share/doc/openscreen/THIRD-PARTY-NOTICES.txt"

# Debian control file
cat <<EOF > "${BUILD_ROOT}/DEBIAN/control"
Package: openscreen
Version: ${PKG_VERSION}
Section: video
Priority: optional
Architecture: ${ARCH}
Maintainer: OpenScreen Contributors <https://github.com/getopenscreen/openscreen>
Depends: libc6, libx11-6, libxext6, libxfixes6, libpulse0, libasound2, ffmpeg
Description: High-Performance Screen Recorder & Native Video Editor
 OpenScreen is a lightweight, native, high-performance screen recording and
 video editing suite written in Zig, featuring auto-zoom, timeline editing,
 local transcription, and AI integration.
EOF

# Build package
mkdir -p "${DIST_DIR}"
dpkg-deb --build --root-owner-group "${BUILD_ROOT}" "${DIST_DIR}/${PKG_NAME}.deb"
echo "Successfully generated: ${DIST_DIR}/${PKG_NAME}.deb"
rm -rf "${BUILD_ROOT}"
