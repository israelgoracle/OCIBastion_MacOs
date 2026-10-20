#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

source_icon="Assets/AppIcon.png"
iconset=".build/AppIcon.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -s format png -z "$doubled" "$doubled" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o Assets/AppIcon.icns
