#!/bin/sh
# Draws wallpaper.html to PNG with headless Chrome: 5120x3200 (16:10, fits
# MacBook and 5K displays). Usage: assets/wallpaper/render.sh [chrome binary]
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
chrome=${1:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
for v in dark light; do
  q=; [ "$v" = light ] && q='?light'
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --virtual-time-budget=3000 --window-size=2560,1600 --force-device-scale-factor=2 \
    --screenshot="$dir/zc-workstation-$v.png" "file://$dir/wallpaper.html$q" 2>/dev/null
done
ls -la "$dir"/*.png
