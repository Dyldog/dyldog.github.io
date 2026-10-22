#!/bin/sh
# Renders the chosen icon (concept C) and UI textures into Pasteruperer/Assets.xcassets.
set -e
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK=$(mktemp -d)
ASSETS=../Pasteruperer/Assets.xcassets

python3 icon.py "$WORK" >/dev/null
python3 textures.py "$WORK"
shot() { "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --default-background-color=00000000 --window-size=$2,$2 --screenshot="$3" "file://$1" >/dev/null 2>&1; }
shot "$WORK/concept-c.html" 1024 "$WORK/icon.png"
shot "$WORK/concrete.html" 512 "$WORK/concrete.png"
shot "$WORK/paper.html" 512 "$WORK/paper.png"

ICONSET="$ASSETS/AppIcon.appiconset"
mkdir -p "$ICONSET" "$ASSETS/Concrete.imageset" "$ASSETS/Paper.imageset" "$ASSETS/AccentColor.colorset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon.png" --out "$ICONSET/icon_${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" --out "$ICONSET/icon_${size}@2x.png" >/dev/null
done
cp "$WORK/concrete.png" "$ASSETS/Concrete.imageset/concrete.png"
cp "$WORK/paper.png" "$ASSETS/Paper.imageset/paper.png"
cp "$WORK/icon.png" icon-1024.png

cat > "$ASSETS/Contents.json" <<JSON
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
python3 - "$ICONSET" <<'PY'
import json, sys
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x",
                       "filename": f"icon_{size}{'@2x' if scale == 2 else ''}.png"})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(sys.argv[1] + "/Contents.json", "w"), indent=2)
PY
for name in Concrete Paper; do
  lower=$(echo $name | tr 'A-Z' 'a-z')
  cat > "$ASSETS/$name.imageset/Contents.json" <<JSON
{ "images" : [ { "idiom" : "universal", "filename" : "$lower.png", "scale" : "1x" } ], "info" : { "author" : "xcode", "version" : 1 } }
JSON
done
# Neon pink, the tag's glow.
cat > "$ASSETS/AccentColor.colorset/Contents.json" <<JSON
{ "colors" : [ { "idiom" : "universal", "color" : { "color-space" : "srgb", "components" : { "red" : "1.000", "green" : "0.176", "blue" : "0.541", "alpha" : "1.000" } } } ],
  "info" : { "author" : "xcode", "version" : 1 } }
JSON
rm -rf "$WORK"
echo "Assets written to $ASSETS"
