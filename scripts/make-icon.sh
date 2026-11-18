#!/bin/sh
# Renders logo.svg into the formats the app needs:
#   Resources/AppIcon.icns          app icon (Finder, Activity Monitor)
#   Resources/MenuIcon.png, @2x     menu bar icon
# Needs rsvg-convert (brew install librsvg). The results are committed, so this only
# has to run when logo.svg changes.
set -eu
cd "$(dirname "$0")/.."
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET" Resources
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" logo.svg -o "$SET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) logo.svg -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
# The logo's tile fills 81 % of the canvas, so 22 pt gives an 18 pt tile in the menu bar.
rsvg-convert -w 22 -h 22 logo.svg -o Resources/MenuIcon.png
rsvg-convert -w 44 -h 44 logo.svg -o "Resources/MenuIcon@2x.png"
echo "wrote Resources/AppIcon.icns and Resources/MenuIcon*.png"
