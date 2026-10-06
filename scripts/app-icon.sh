#!/bin/sh
# Renders App/Icon/AppIcon.svg (64 px and up) and App/Icon/AppIcon-small.svg (16 and 32 px: no ring, no glow) into
# App/Resources/Assets.xcassets/AppIcon.appiconset. Needs rsvg-convert (brew install librsvg).
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/App/Icon"
OUT="$REPO/App/Resources/Assets.xcassets/AppIcon.appiconset"

render() { # <svg> <pixels> <file>
	rsvg-convert -w "$2" -h "$2" "$SRC/$1" -o "$OUT/$3"
}

render AppIcon-small.svg 16 icon_16x16.png
render AppIcon-small.svg 32 icon_16x16@2x.png
render AppIcon-small.svg 32 icon_32x32.png
render AppIcon.svg 64 icon_32x32@2x.png
render AppIcon.svg 128 icon_128x128.png
render AppIcon.svg 256 icon_128x128@2x.png
render AppIcon.svg 256 icon_256x256.png
render AppIcon.svg 512 icon_256x256@2x.png
render AppIcon.svg 512 icon_512x512.png
render AppIcon.svg 1024 icon_512x512@2x.png
