#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_IMAGE="${1:-$ROOT_DIR/Resources/AppIcon-1024.png}"
ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
ICNS_FILE="$ROOT_DIR/Resources/AppIcon.icns"
TEMP_ICNS_FILE="$ICNS_FILE.tmp"

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  echo "missing app icon master: $SOURCE_IMAGE" >&2
  exit 1
fi

PIXEL_WIDTH="$(sips -g pixelWidth "$SOURCE_IMAGE" | awk '/pixelWidth/ {print $2}')"
PIXEL_HEIGHT="$(sips -g pixelHeight "$SOURCE_IMAGE" | awk '/pixelHeight/ {print $2}')"

if [[ "$PIXEL_WIDTH" != "1024" || "$PIXEL_HEIGHT" != "1024" ]]; then
  echo "app icon master must be 1024x1024, got ${PIXEL_WIDTH}x${PIXEL_HEIGHT}" >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR"

render_icon() {
  local pixels="$1"
  local filename="$2"
  sips -z "$pixels" "$pixels" "$SOURCE_IMAGE" --out "$ICONSET_DIR/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

rm -f "$TEMP_ICNS_FILE"
trap 'rm -f "$TEMP_ICNS_FILE"' EXIT
swift "$ROOT_DIR/script/generate_icns.swift" "$ICONSET_DIR" "$TEMP_ICNS_FILE"
mv "$TEMP_ICNS_FILE" "$ICNS_FILE"
trap - EXIT

echo "generated $ICNS_FILE"
