#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from Resources/AppIcon.svg.
# Requires rsvg-convert (brew install librsvg); Quick Look renders SVGs onto white and loses the transparent corners.
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$NATIVE_DIR/Resources/AppIcon.svg"
OUT="$NATIVE_DIR/Resources/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found. Install it with: brew install librsvg" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$SRC" -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" "$SRC" -o "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
