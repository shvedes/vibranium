#!/usr/bin/env bash

# Source: Omarchy

# Get the active monitor (focused)
MONITOR_INFO=$(hyprctl monitors -j | jq -r '.[] | select(.focused == true)')

ACTIVE_MONITOR=$(jq -r '.name' <<< "$MONITOR_INFO")
CURRENT_SCALE=$(jq -r '.scale' <<< "$MONITOR_INFO")
WIDTH=$(jq -r '.width' <<< "$MONITOR_INFO")
HEIGHT=$(jq -r '.height' <<< "$MONITOR_INFO")
REFRESH_RATE=$(jq -r '.refreshRate' <<< "$MONITOR_INFO")

# Auto scale based on HEIGHT (more reliable than WIDTH for different aspect ratios)
if (( HEIGHT <= 720 )); then
  NEW_SCALE=1
elif (( HEIGHT <= 900 )); then
  NEW_SCALE=1
elif (( HEIGHT <= 1080 )); then
  NEW_SCALE=1
elif (( HEIGHT <= 1200 )); then
  NEW_SCALE=1.1
elif (( HEIGHT <= 1440 )); then
  NEW_SCALE=1.25
elif (( HEIGHT <= 1600 )); then
  NEW_SCALE=1.4
elif (( HEIGHT <= 1800 )); then
  NEW_SCALE=1.5
elif (( HEIGHT <= 2160 )); then
  NEW_SCALE=2
elif (( HEIGHT <= 2400 )); then
  NEW_SCALE=2
elif (( HEIGHT <= 2880 )); then
  NEW_SCALE=2.5
elif (( HEIGHT <= 3200 )); then
  NEW_SCALE=2.5
elif (( HEIGHT <= 3840 )); then
  NEW_SCALE=3
elif (( HEIGHT <= 4320 )); then
  NEW_SCALE=3.5
else
  NEW_SCALE=4
fi

# Apply scale
hyprctl -q keyword misc:disable_scale_notification true
hyprctl -q keyword monitor "$ACTIVE_MONITOR,${WIDTH}x${HEIGHT}@${REFRESH_RATE},auto,$NEW_SCALE"
hyprctl -q keyword misc:disable_scale_notification false
notify-send -r $RANDOM -t 7000 "Vibranium" "Display scaling set to ${NEW_SCALE}x"

# Save to config file
echo "monitor = $ACTIVE_MONITOR, ${WIDTH}x${HEIGHT}@${REFRESH_RATE}, auto, $NEW_SCALE" >> "$XDG_CONFIG_HOME/hypr/hyprland.conf.d/monitors.conf"
