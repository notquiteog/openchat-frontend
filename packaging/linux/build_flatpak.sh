#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${1:-$(awk '/^version:/ {print $2}' "$ROOT_DIR/pubspec.yaml" | tr -d '\r')}"
APP_ID="win.openchat.OpenChat"
BUNDLE_DIR="$ROOT_DIR/build/linux/x64/release/bundle"
OUTPUT_DIR="$ROOT_DIR/build/linux-packages"
WORK_ROOT="$ROOT_DIR/build/linux-flatpak"
SOURCE_DIR="$WORK_ROOT/source"
BUILD_DIR="$WORK_ROOT/build-dir"
REPO_DIR="$WORK_ROOT/repo"
MANIFEST="$WORK_ROOT/${APP_ID}.yml"
FLATPAK_PATH="$OUTPUT_DIR/openchat-${VERSION}-linux-x86_64.flatpak"
LDCONFIG="${LDCONFIG:-$(command -v ldconfig || command -v /sbin/ldconfig || true)}"

if [ ! -x "$BUNDLE_DIR/openchat" ]; then
  echo "Linux bundle not found at $BUNDLE_DIR. Run flutter build linux --release first." >&2
  exit 1
fi

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "flatpak-builder is required to create the Flatpak bundle." >&2
  exit 1
fi

if ! command -v flatpak >/dev/null 2>&1; then
  echo "flatpak is required to create the Flatpak bundle." >&2
  exit 1
fi

if [ -z "$LDCONFIG" ] || [ ! -x "$LDCONFIG" ]; then
  echo "ldconfig is required to locate bundled tray libraries." >&2
  exit 1
fi

rm -rf "$WORK_ROOT"
mkdir -p "$SOURCE_DIR/openchat-bundle" "$OUTPUT_DIR"
cp -a "$BUNDLE_DIR/." "$SOURCE_DIR/openchat-bundle/"

copy_runtime_lib() {
  local soname="$1"
  local path
  path="$("$LDCONFIG" -p | awk -v lib="$soname" '$1 == lib {print $NF; exit}')"
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    echo "Required Flatpak-bundled library not found: $soname" >&2
    exit 1
  fi
  cp -L "$path" "$SOURCE_DIR/openchat-bundle/lib/$soname"
}

copy_runtime_lib libayatana-appindicator3.so.1
copy_runtime_lib libayatana-indicator3.so.7
copy_runtime_lib libayatana-ido3-0.4.so.0
copy_runtime_lib libdbusmenu-glib.so.4
copy_runtime_lib libdbusmenu-gtk3.so.4

install -Dm644 "$ROOT_DIR/packaging/linux/shared/${APP_ID}.desktop" \
  "$SOURCE_DIR/${APP_ID}.desktop"
install -Dm644 "$ROOT_DIR/packaging/linux/shared/${APP_ID}.metainfo.xml" \
  "$SOURCE_DIR/${APP_ID}.metainfo.xml"
install -Dm644 "$ROOT_DIR/web/icons/Icon-512.png" "$SOURCE_DIR/${APP_ID}.png"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$SOURCE_DIR/${APP_ID}.desktop" >&2
fi

if command -v appstreamcli >/dev/null 2>&1; then
  appstreamcli validate --no-net "$SOURCE_DIR/${APP_ID}.metainfo.xml" >&2
fi

cat > "$SOURCE_DIR/openchat-flatpak" <<'EOF'
#!/bin/sh
export LD_LIBRARY_PATH="/app/openchat/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /app/openchat/openchat "$@"
EOF
chmod +x "$SOURCE_DIR/openchat-flatpak"

cat > "$MANIFEST" <<EOF
app-id: ${APP_ID}
runtime: org.gnome.Platform
runtime-version: '50'
sdk: org.gnome.Sdk
command: openchat
finish-args:
  - --share=ipc
  - --socket=fallback-x11
  - --socket=wayland
  - --socket=pulseaudio
  - --share=network
  - --device=all
  - --filesystem=xdg-documents
  - --filesystem=xdg-download
  - --filesystem=xdg-pictures
  - --filesystem=xdg-videos
  - --talk-name=org.freedesktop.Notifications
  - --talk-name=org.freedesktop.secrets
  - --talk-name=org.kde.StatusNotifierWatcher
modules:
  - name: openchat
    buildsystem: simple
    build-commands:
      - mkdir -p /app/openchat /app/bin /app/share/applications /app/share/icons/hicolor/512x512/apps /app/share/metainfo
      - cp -a openchat-bundle/. /app/openchat/
      - install -Dm755 openchat-flatpak /app/bin/openchat
      - install -Dm644 ${APP_ID}.desktop /app/share/applications/${APP_ID}.desktop
      - install -Dm644 ${APP_ID}.metainfo.xml /app/share/metainfo/${APP_ID}.metainfo.xml
      - install -Dm644 ${APP_ID}.png /app/share/icons/hicolor/512x512/apps/${APP_ID}.png
    sources:
      - type: dir
        path: ${SOURCE_DIR}
EOF

flatpak-builder \
  --force-clean \
  --repo="$REPO_DIR" \
  --default-branch=stable \
  --mirror-screenshots-url=https://dl.flathub.org/media \
  "$BUILD_DIR" \
  "$MANIFEST" >&2
flatpak build-bundle "$REPO_DIR" "$FLATPAK_PATH" "$APP_ID" stable >&2
echo "$FLATPAK_PATH"
