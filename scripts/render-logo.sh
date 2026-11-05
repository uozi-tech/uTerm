#!/usr/bin/env zsh
# Regenerate the PNGs derived from the two logo masters:
#   - Resources/Logo/ULogoMark.svg → ULogoMark.imageset (in-app logo, 256 / 512)
#   - AppIcon.appiconset/icon_512@2x.png → every smaller macOS app icon size
#
# The app icon master is the committed 1024 PNG, not the SVG: the shipped icon
# artwork was redrawn without updating the SVG, so rendering from it would bring
# back the old artwork. To change the icon, replace icon_512@2x.png and rerun.
#
# Small sizes must be plain downscales of the master. macOS checks each size of
# an icon separately and shows any it rejects shrunken on a gray plate, which
# hand-sharpened 16 and 64 px PNGs triggered (in System Settings lists, say).
#
# This script leaves both Contents.json files and icon_ios_1024.png alone.
# Requires: rsvg-convert (brew install librsvg), sips (ships with macOS)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "❌ rsvg-convert not found. Install: brew install librsvg"
  exit 1
fi

# --- in-app logo imageset -------------------------------------------------
SRC="Resources/Logo/ULogoMark.svg"
IMG="uTerm/Assets.xcassets/ULogoMark.imageset"
rsvg-convert --width 256 --height 256 "$SRC" -o "$IMG/ULogoMark.png"
rsvg-convert --width 512 --height 512 "$SRC" -o "$IMG/ULogoMark@2x.png"
echo "✅ imageset → $IMG"

# --- macOS app icon -------------------------------------------------------
ICON="uTerm/Assets.xcassets/AppIcon.appiconset"
MASTER="$ICON/icon_512@2x.png"
master_width=$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/ { print $2 }')
if [[ "$master_width" != 1024 ]]; then
  echo "❌ $MASTER must be 1024 px wide, got $master_width"
  exit 1
fi

downscale() { sips -z "$1" "$1" "$MASTER" --out "$ICON/$2" >/dev/null; }
downscale 16  icon_16.png
downscale 32  icon_16@2x.png
downscale 32  icon_32.png
downscale 64  icon_32@2x.png
downscale 128 icon_128.png
downscale 256 icon_128@2x.png
downscale 256 icon_256.png
downscale 512 icon_256@2x.png
downscale 512 icon_512.png
echo "✅ app icon → $ICON"
