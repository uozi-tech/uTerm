#!/usr/bin/env zsh
# Render Resources/Logo/ULogoMark.svg into the asset catalog:
#   - uTerm/Assets.xcassets/ULogoMark.imageset   (in-app logo, 256 / 512)
#   - uTerm/Assets.xcassets/AppIcon.appiconset   (macOS app icon, 16…1024)
# Each size is rendered straight from the vector for maximum sharpness.
# NOTE: quit Xcode before running — Xcode caches the open asset catalog and can
#       overwrite the regenerated Contents.json with its stale in-memory state.
# Requires: rsvg-convert (brew install librsvg)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "❌ rsvg-convert not found. Install: brew install librsvg"
  exit 1
fi

SRC="Resources/Logo/ULogoMark.svg"
render() { rsvg-convert --width "$1" --height "$1" "$SRC" -o "$2"; }

# --- in-app logo imageset -------------------------------------------------
IMG="uTerm/Assets.xcassets/ULogoMark.imageset"
mkdir -p "$IMG"
render 256 "$IMG/ULogoMark.png"
render 512 "$IMG/ULogoMark@2x.png"

cat > "$IMG/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "ULogoMark.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "ULogoMark@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
echo "✅ imageset → $IMG"

# --- macOS app icon -------------------------------------------------------
ICON="uTerm/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICON"
render 16   "$ICON/icon_16.png"
render 32   "$ICON/icon_16@2x.png"
render 32   "$ICON/icon_32.png"
render 64   "$ICON/icon_32@2x.png"
render 128  "$ICON/icon_128.png"
render 256  "$ICON/icon_128@2x.png"
render 256  "$ICON/icon_256.png"
render 512  "$ICON/icon_256@2x.png"
render 512  "$ICON/icon_512.png"
render 1024 "$ICON/icon_512@2x.png"

cat > "$ICON/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon_16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
echo "✅ app icon → $ICON"
