#!/bin/bash

STATE_FILE="$VIBRANIUM_STATE/nightshift"

vb-cmd-nightshift --set 5000
hyprctl -q hyprsunset identity

printf '%s' "suspended" >"$STATE_FILE"
