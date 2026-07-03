#!/bin/bash

# Get all active monitor names from hyprctl
MONITOR_LIST=$(hyprctl -j monitors | jq -r '.[].name')
if [[ -z "$MONITOR_LIST" ]]; then
  exit 0
fi

# Verify state file format before parsing
read -r HEADER < "$VIBRANIUM_STATE/monitors" 2>/dev/null || exit 0
[[ "$HEADER" == "# output:i2c:level:gamma:mult" ]] || exit 0

# Pre-parse state: i2c bus + cached level per monitor
# Also captures gamma from state to detect prior gamma dimming.
declare -A BUS CACHED
GAMMA=100
FIRST_MON=""
while IFS=: read -r output i2c level g _; do
  [[ "$output" == \#* || -z "$output" ]] && continue
  [[ -n "$i2c" ]] && BUS[$output]="$i2c"
  [[ -n "$level" ]] && CACHED[$output]="$level"
  [[ -n "$g" && "$g" =~ ^[0-9]+$ && "$g" != "100" ]] && GAMMA=$g
  [[ -z "$FIRST_MON" ]] && FIRST_MON="$output"
done < "$VIBRANIUM_STATE/monitors"

# Sync each monitor's cached level with actual hardware
while IFS= read -r monitor; do
  cached="${CACHED[$monitor]:-}"
  bus="${BUS[$monitor]:-}"
  [[ -z "$cached" || -z "$bus" ]] && continue

  raw=$(ddcutil --bus "$bus" getvcp 10 2>/dev/null)
  [[ "$raw" =~ current\ value\ =\ +([0-9]+) ]] || continue
  actual="${BASH_REMATCH[1]}"
  [[ "$cached" == "$actual" ]] && continue

  vb-core-brightness --quiet --set "$actual" --monitor "$monitor"
done <<< "$MONITOR_LIST"

# Restore gamma when it was dimmed (e.g. from negative brightness in prior session).
# --set with a non-negative value triggers gamma restoration inside vb-core-brightness
# even when the target brightness equals the current hardware level.
if [[ "$GAMMA" != "100" && -n "$FIRST_MON" ]]; then
  cached="${CACHED[$FIRST_MON]:-}"
  vb-core-brightness --quiet --set "${cached:-0}" --monitor "$FIRST_MON"
fi
