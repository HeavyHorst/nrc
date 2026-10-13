#!/usr/bin/env bash
set -euo pipefail

# ImageMagick 7 with SVG support. Run from any directory.
root="$(dirname "$(dirname "$(realpath "$0")")")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

magick -density 768 -background none "$root/logo/logo.svg" -resize 1024x1024 \
  -gravity center -extent 1024x1024 "$scratch/mark.png"
magick "$scratch/mark.png" "$root/logo/logo.png"
magick "$scratch/mark.png" -background white -alpha remove -alpha off \
  -quality 95 "$root/logo/logo_full.jpg"

# Solid tiles keep the mark legible on either browser theme. The mark fits
# within the central 60% so installed icons also have ample platform padding.
magick "$scratch/mark.png" -channel RGB -negate +channel -resize 60% \
  -gravity center -background '#111111' -extent 1024x1024 \
  -alpha remove -alpha off "$scratch/tile.png"
magick "$scratch/tile.png" -resize 256x256 "$root/client/favicon.png"
magick "$scratch/tile.png" -define icon:auto-resize=64,48,32,16 "$root/client/favicon.ico"
magick "$root/client/favicon.png" "$root/logo/favicon.png"
for size in 192 512; do
  magick "$scratch/tile.png" -resize "${size}x${size}" "$root/client/icons/icon-${size}.png"
done
magick "$scratch/tile.png" -resize 180x180 "$root/client/icons/apple-touch-icon.png"
