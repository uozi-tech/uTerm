#!/usr/bin/env zsh
# Render Resources/Logo/ULogoMark.svg into uTerm/Assets.xcassets/ULogoMark.imageset
# Requires: rsvg-convert (brew install librsvg)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "❌ rsvg-convert not found. Install: brew install librsvg"
  exit 1
fi

SRC="Resources/Logo/ULogoMark.svg"
OUT="uTerm/Assets.xcassets/ULogoMark.imageset"
mkdir -p "$OUT"

rsvg-convert --width 256 --height 256 "$SRC" -o "$OUT/ULogoMark.png"
rsvg-convert --width 512 --height 512 "$SRC" -o "$OUT/ULogoMark@2x.png"

cat > "$OUT/Contents.json" <<'JSON'
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

echo "✅ Rendered $OUT/ULogoMark.png + ULogoMark@2x.png"
