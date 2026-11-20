#!/usr/bin/env bash
set -euo pipefail

# Build OpenScreen RPM package (.rpm)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
PKG_VERSION="1.0.0"
RPM_ROOT="/tmp/openscreen_rpm_build"

echo "=== Building OpenScreen ReleaseFast ==="
cd "${ROOT_DIR}"
zig build -Doptimize=ReleaseFast

echo "=== Creating RPM Build Tree ==="
rm -rf "${RPM_ROOT}"
mkdir -p "${RPM_ROOT}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat <<EOF > "${RPM_ROOT}/SPECS/openscreen.spec"
Name:           openscreen
Version:        ${PKG_VERSION}
Release:        1%{?dist}
Summary:        High-Performance Screen Recorder & Native Video Editor
License:        MIT and LGPLv2.1+
URL:            https://github.com/getopenscreen/openscreen

Requires:       glibc, libX11, libXext, libXfixes, pulseaudio-libs, alsa-lib, ffmpeg

%description
OpenScreen is a lightweight, native, high-performance screen recording and
video editing suite written in Zig, featuring auto-zoom, timeline editing,
local transcription, and AI integration.

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons/hicolor/512x512/apps
mkdir -p %{buildroot}/usr/share/openscreen
mkdir -p %{buildroot}/usr/share/doc/openscreen

install -m 755 ${ROOT_DIR}/zig-out/bin/openscreen %{buildroot}/usr/bin/openscreen
install -m 644 ${SCRIPT_DIR}/openscreen.desktop %{buildroot}/usr/share/applications/openscreen.desktop
install -m 644 ${ROOT_DIR}/assets/openscreen.png %{buildroot}/usr/share/icons/hicolor/512x512/apps/openscreen.png
cp -r ${ROOT_DIR}/assets %{buildroot}/usr/share/openscreen/
install -m 644 ${ROOT_DIR}/LICENSE %{buildroot}/usr/share/doc/openscreen/LICENSE
install -m 644 ${ROOT_DIR}/THIRD-PARTY-NOTICES.md %{buildroot}/usr/share/doc/openscreen/THIRD-PARTY-NOTICES.txt

%files
/usr/bin/openscreen
/usr/share/applications/openscreen.desktop
/usr/share/icons/hicolor/512x512/apps/openscreen.png
/usr/share/openscreen/
%doc /usr/share/doc/openscreen/LICENSE
%doc /usr/share/doc/openscreen/THIRD-PARTY-NOTICES.txt

%changelog
* Wed Nov 20 2026 OpenScreen Contributors <openscreen@users.noreply.github.com> - 1.0.0-1
- Initial native Zig release with 100% parity
EOF

if command -v rpmbuild &>/dev/null; then
    rpmbuild --define "_topdir ${RPM_ROOT}" -bb "${RPM_ROOT}/SPECS/openscreen.spec"
    mkdir -p "${DIST_DIR}"
    cp "${RPM_ROOT}"/RPMS/*/*.rpm "${DIST_DIR}/"
    echo "RPM successfully built into ${DIST_DIR}"
else
    echo "rpmbuild not installed; RPM spec generated at ${RPM_ROOT}/SPECS/openscreen.spec"
fi
