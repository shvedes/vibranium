#!/bin/bash

# Cache the available power profile names for consumers like
# vb-core-gamemode, saving them the powerprofilesctl (python)
# startup on every launch. One canonical profile name per line, daemon
# order, e.g.:
#   performance
#   balanced
#   power-saver

STATE_FILE="$VIBRANIUM_STATE/power-profiles"

# Profile header lines look like "* performance:" (active) or
# "  balanced:", while driver/detail lines always carry content after
# the colon and never match.
raw="$(powerprofilesctl list 2> /dev/null | sed -nE 's/^[*[:space:]]+([a-zA-Z0-9-]+):$/\1/p')"

# Empty output: daemon unreachable or power-profiles-daemon missing.
# Leave any existing cache in place rather than clobbering it with nothing.
[[ -n "$raw" ]] || exit 0

# Overwrite only when the cached contents diverge from fresh data.
if [[ -f "$STATE_FILE" ]] && [[ "$(< "$STATE_FILE")" == "$raw" ]]; then
  exit 0
fi

printf '%s\n' "$raw" > "$STATE_FILE"
