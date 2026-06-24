#!/usr/bin/env bash

# Initial state for the hyprsunset
if [[ "$CHASSIS_TYPE" != vm ]]; then
  printf "suspended" >"$HOME/.local/state/vibranium/nightshift"
fi

if [[ -f /tmp/vibranium-nm.removed ]]; then
  : >"$HOME/.local/state/vibranium/network-notify"
fi

# First run marker
: >"$HOME/.local/state/vibranium/first-run"
