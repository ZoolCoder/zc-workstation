#!/usr/bin/env bash
# The ZCBar app's attention count, from the file it writes before each zcbar_changed event: green when nothing needs doing.
export PATH="/opt/homebrew/bin:$PATH"
source "$CONFIG_DIR/colors.sh"
file="$HOME/Library/Application Support/ZCBar/attention"
[ -f "$file" ] || { sketchybar --set "$NAME" drawing=off; exit 0; }
count=$(<"$file")
case $count in
  0) sketchybar --set "$NAME" drawing=on icon.color="$GREEN" label.drawing=off ;;
  setup) sketchybar --set "$NAME" drawing=on icon.color="$PEACH" label.drawing=on label="setup" ;;
  *) sketchybar --set "$NAME" drawing=on icon.color="$PEACH" label.drawing=on label="$count" ;;
esac
