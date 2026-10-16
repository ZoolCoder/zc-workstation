#!/usr/bin/env bash
# Changes outstanding against the zc-workstation config, from the file `zc-workstation drift` saves each morning; hidden while there is none.
source "$CONFIG_DIR/colors.sh"
file="${XDG_STATE_HOME:-$HOME/.local/state}/zc-workstation/drift.json"
[ -f "$file" ] || { sketchybar --set "$NAME" drawing=off; exit 0; }
changes=$(sed -n 's/^ *"changes": \([0-9]*\).*/\1/p' "$file")
if grep -q '"error"' "$file"; then
  sketchybar --set "$NAME" drawing=on icon.color="$RED" label.drawing=on label="?"
elif [ "${changes:-0}" -eq 0 ]; then
  sketchybar --set "$NAME" drawing=off
else
  sketchybar --set "$NAME" drawing=on icon.color="$PEACH" label.drawing=on label="$changes"
fi
