#!/bin/sh
# Renders icon concepts (HTML wrapping SVG) to 1024px PNGs with headless Chrome.
# Usage: render.sh <dir containing concept-*.html>
set -e
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for html in "$1"/*.html; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=1024,1024 \
    --screenshot="${html%.html}.png" "file://$html" >/dev/null 2>&1
  echo "${html%.html}.png"
done
