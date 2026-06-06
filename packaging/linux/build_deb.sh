#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${1:-$(awk '/^version:/ {print $2}' "$ROOT_DIR/pubspec.yaml" | tr -d '\r')}"
ARCH="amd64"
PACKAGE_NAME="openchat"
APP_ID="win.openchat.OpenChat"
BUNDLE_DIR="$ROOT_DIR/build/linux/x64/release/bundle"
OUTPUT_DIR="$ROOT_DIR/build/linux-packages"
WORK_DIR="$ROOT_DIR/build/linux-deb/${PACKAGE_NAME}_${VERSION}_${ARCH}"
DEB_PATH="$OUTPUT_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"

if [ ! -x "$BUNDLE_DIR/openchat" ]; then
  echo "Linux bundle not found at $BUNDLE_DIR. Run flutter build linux --release first." >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p \
  "$WORK_DIR/DEBIAN" \
  "$WORK_DIR/opt/openchat" \
  "$WORK_DIR/usr/bin" \
  "$WORK_DIR/usr/share/applications" \
  "$WORK_DIR/usr/share/icons/hicolor/512x512/apps" \
  "$WORK_DIR/usr/share/metainfo" \
  "$OUTPUT_DIR"

cp -a "$BUNDLE_DIR/." "$WORK_DIR/opt/openchat/"
ln -s /opt/openchat/openchat "$WORK_DIR/usr/bin/openchat"
install -Dm644 "$ROOT_DIR/packaging/linux/shared/${APP_ID}.desktop" \
  "$WORK_DIR/usr/share/applications/${APP_ID}.desktop"
install -Dm644 "$ROOT_DIR/packaging/linux/shared/${APP_ID}.metainfo.xml" \
  "$WORK_DIR/usr/share/metainfo/${APP_ID}.metainfo.xml"
install -Dm644 "$ROOT_DIR/web/icons/Icon-512.png" \
  "$WORK_DIR/usr/share/icons/hicolor/512x512/apps/${APP_ID}.png"

cat > "$WORK_DIR/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: OpenChat <support@openchat.win>
Depends: libc6 (>= 2.31), libstdc++6, zlib1g, libgtk-3-0, libsecret-1-0, libx11-6, libxi6, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libmpv2
Homepage: https://openchat.win
Description: Open-source E2E encrypted messenger with PGP
 OpenChat is an end-to-end encrypted messenger with PGP-based identity,
 group chats, channels, calls, and premium payment support.
EOF

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$WORK_DIR/usr/share/applications/${APP_ID}.desktop"
fi

dpkg-deb --build --root-owner-group "$WORK_DIR" "$DEB_PATH" >&2
echo "$DEB_PATH"
