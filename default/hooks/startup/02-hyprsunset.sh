#!/bin/bash

# If state file doesn't exist - create one and disable
# night light (by default). We still need hyprsunset
# running in background because screen flashing effect
# depends on it. It is not the best solution though, and
# because of the while loop we must keep this check at the end
if [[ "$CHASSIS_TYPE" != vm ]]; then
  if [[ ! -f "$VIBRANIUM_STATE/nightshift" ]]; then
    peintf 'suspended' >"$VIBRANIUM_STATE/nightshift"
    hyprctl -q hyprsunset identity
  elif [[ "$(<"$VIBRANIUM_STATE/nightshift")" == "suspended" ]]; then
    while ! pidof -q hyprsunset; do
      sleep 0.05
    done
    hyprctl -q hyprsunset identity
  fi
fi
