#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <linux-bundle-dir>" >&2
  exit 2
fi

BUNDLE_DIR="$1"
BUNDLE_LIB_DIR="${BUNDLE_DIR}/lib"
LDCONFIG="${LDCONFIG:-$(command -v ldconfig || command -v /sbin/ldconfig || true)}"

if [ ! -d "$BUNDLE_LIB_DIR" ]; then
  echo "Bundle lib directory not found: $BUNDLE_LIB_DIR" >&2
  exit 1
fi

if [ -z "$LDCONFIG" ] || [ ! -x "$LDCONFIG" ]; then
  echo "ldconfig is required to locate Linux tray runtime libraries." >&2
  exit 1
fi

sonames=(
  libayatana-appindicator3.so.1
  libayatana-indicator3.so.7
  libayatana-ido3-0.4.so.0
  libdbusmenu-glib.so.4
  libdbusmenu-gtk3.so.4
)

for soname in "${sonames[@]}"; do
  path="$("$LDCONFIG" -p | awk -v lib="$soname" '$1 == lib {print $NF; exit}')"
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    echo "Required Linux tray runtime library not found: $soname" >&2
    exit 1
  fi
  cp -L "$path" "$BUNDLE_LIB_DIR/$soname"
done
