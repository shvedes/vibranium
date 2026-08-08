#!/bin/bash

# Get all active monitor names from Hyprland.
MONITOR_LIST=$(hyprctl -j monitors | jq -r '.[].name')

if [[ -z "$MONITOR_LIST" ]]; then
  exit 0
fi

if [[ -f "$VIBRANIUM_STATE/monitors" ]]; then
  read -r HEADER < "$VIBRANIUM_STATE/monitors"
fi

if [[ "$HEADER" != "# output:i2c:level:gamma:mult" ]]; then
  exit 0
fi

# Cached monitor data:
#   BUS    -> DDC/CI bus number
#   CACHED -> Cached hardware brightness
#   GAMMA  -> Cached gamma value (100 = normal)
declare -A BUS CACHED
FIRST_MON=""
GAMMA=100

while IFS=: read -r output i2c level gamma _; do
  # Ignore comments and empty lines.
  if [[ "$output" != \#* && -n "$output" ]]; then

    # Cache the DDC/CI bus.
    if [[ -n "$i2c" ]]; then
      BUS[$output]="$i2c"
    fi

    # Cache the last known hardware brightness.
    if [[ -n "$level" ]]; then
      CACHED[$output]="$level"
    fi

    # Remember whether gamma dimming was active.
    if [[ -n "$gamma" && "$gamma" =~ ^[0-9]+$ ]]; then
      if [[ "$gamma" != "100" ]]; then
        GAMMA="$gamma"
      fi
    fi

    # Save the first monitor for possible gamma restoration.
    if [[ -z "$FIRST_MON" ]]; then
      FIRST_MON="$output"
    fi
  fi
done < "$VIBRANIUM_STATE/monitors"

# Synchronize cached brightness with actual monitor brightness.
while IFS= read -r monitor; do
  cached="${CACHED[$monitor]:-}"
  bus="${BUS[$monitor]:-}"

  # Skip monitors without cached state or DDC support.
  if [[ -n "$cached" && -n "$bus" ]]; then

    raw=$(ddcutil --bus "$bus" getvcp 10 2> /dev/null)

    # Parse the current hardware brightness.
    if [[ "$raw" =~ current\ value\ =\ +([0-9]+) ]]; then
      actual="${BASH_REMATCH[1]}"

      # Update the cache only if hardware changed externally.
      if [[ "$cached" != "$actual" ]]; then
        vb-core-brightness --quiet --set "$actual" --monitor "$monitor"
      fi
    fi
  fi
done <<< "$MONITOR_LIST"

# Restore gamma if the previous session used software dimming.
# Calling --set with the current brightness is enough to restore gamma.
if [[ "$GAMMA" != "100" ]]; then
  if [[ -n "$FIRST_MON" ]]; then
    cached="${CACHED[$FIRST_MON]:-}"
    vb-core-brightness --quiet --set "${cached:-0}" --monitor "$FIRST_MON"
  fi
fi
