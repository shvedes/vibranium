#!/usr/bin/env bash

_get_power_profile() {
  if [[ "$CHASSIS_TYPE" == desktop ]]; then
    echo "performance"
  else
    local battery_file
    local battery_status

    battery_file="/sys/class/power_supply/BAT0/status"

    if [[ -f "$battery_file" ]]; then
      battery_status=$(< "$battery_file")

      if [[ "$battery_status" == "Charging" ]]; then
        echo "performance"
      else
        echo "balanced"
      fi
    else
      echo "balanced"
    fi

  fi
}

POWER_PROFILE="$(_get_power_profile)"
vb-core-power "$POWER_PROFILE"

if [[ "$POWER_PROFILE" == "performance" ]]; then
  if [[ "$CHASSIS_TYPE" == desktop ]]; then
    msg="Vibranium is running on a desktop. Performance power profile was set explicitly"
  else
    msg="You're running off AC. Performance power profile was set explicitly"
  fi

  notify-send -r $RANDOM -t 10000 "Power Management" "$msg"
fi
