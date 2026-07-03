#!/bin/bash

for CANDIDATE in /sys/class/power_supply/*; do
  [[ -f "$CANDIDATE/type" ]] || continue
  [[ "$(<"$CANDIDATE/type")" == "Battery" ]] || continue
  BATTERY_PATH="$CANDIDATE"
  break
done

if [[ -z "$BATTERY_PATH" ]]; then
  exit 0
fi

CAPACITY=$(<"$BATTERY_PATH/capacity")

if [[ -z "$CAPACITY" ]]; then
  exit 0
fi

if ((CAPACITY <= 25)) && ((CAPACITY > 15)); then
  notify-send -t 15000 -r 4455 "You're Low On Battery" "Battery at ${CAPACITY}%"
elif ((CAPACITY <= 15)); then
  notify-send -t 30000 -r 4455 -u critical "You're Low On Battery" "Battery at ${CAPACITY}%"
fi
