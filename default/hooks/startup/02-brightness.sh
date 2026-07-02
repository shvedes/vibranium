#!/bin/bash

GAMMA_MIN=10
RESTORED_GAMMA=100

if [[ -f "$VIBRANIUM_STATE/monitors" ]]; then
  while IFS=: read -r _ _ _ gamma; do
    if [[ "$gamma" =~ ^[0-9]+$ ]] && ((gamma >= GAMMA_MIN && gamma <= 100)); then
      hyprctl -q hyprsunset gamma "$gamma"
      RESTORED_GAMMA=$gamma
      break
    fi
  done <"$VIBRANIUM_STATE/monitors"
fi

CURRENT_BRIGHTNESS="$(ddcutil getvcp 10 2>/dev/null | sed -n 's/.*current value = *\([0-9]\+\).*/\1/p')"

if [[ -z "$CURRENT_BRIGHTNESS" ]]; then
  exit
fi

CURRENT_MONITOR="$(hyprctl -j monitors | jq -r '.[] | select(.focused == true) | .name')"

# Parse state file — supports both 3-field (i2c:output:level) and
# 4-field (i2c:output:level:gamma) formats.
while IFS=: read -r _ monitor level _; do
  if [[ $monitor == "$CURRENT_MONITOR" ]]; then
    CACHED_BRIGHTNESS=$level
    break
  fi
done < "$VIBRANIUM_STATE/monitors"

if [[ -z "$CACHED_BRIGHTNESS" ]]; then
  exit
fi

# vb-core-brightness --set resets gamma to 100, so re-apply the
# persisted value after the brightness sync.
if [[ -n "$CACHED_BRIGHTNESS" && "$CACHED_BRIGHTNESS" != "$CURRENT_BRIGHTNESS" ]]; then
  vb-core-brightness --quiet --set "$CURRENT_BRIGHTNESS"

  if ((RESTORED_GAMMA < 100)); then
    hyprctl -q hyprsunset gamma "$RESTORED_GAMMA"
  fi
fi
