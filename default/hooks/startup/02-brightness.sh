#!/usr/bin/env bash

# This function handles cases where the monitor brightness might have been changed
# manually, dual-boot (e.g. Monitorian), or through any external means outside the script.
# It checks the current brightness via DDC, compares it with the cached value,
# and updates it if there's a discrepancy.

CURRENT_BRIGHTNESS="$(ddcutil getvcp 10 2>/dev/null | sed -n 's/.*current value = *\([0-9]\+\).*/\1/p')"

if [[ -z "$CURRENT_BRIGHTNESS" ]]; then
  exit
fi

CURRENT_MONITOR="$(hyprctl -j monitors | jq -r '.[] | select(.focused == true) | .name')"

while IFS=: read -r _ monitor level; do
  if [[ $monitor == "$CURRENT_MONITOR" ]]; then
    CACHED_BRIGHTNESS=$level
    break
  fi
done < "$VIBRANIUM_STATE/monitors"

if [[ -z "$CACHED_BRIGHTNESS" ]]; then
  exit
fi

if [[ -n "$CACHED_BRIGHTNESS" && "$CACHED_BRIGHTNESS" != "$CURRENT_BRIGHTNESS" ]]; then
  vb-core-brightness --quiet --set "$CURRENT_BRIGHTNESS"
fi
