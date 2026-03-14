#!/usr/bin/env bash

# Initial state for the hyprsunset
if [[ "$CHASSIS_TYPE" =! vm ]]; then
  printf "suspended" > "$HOME/.local/state/vibranium/nightshift"
  UpdateSummary "State: initialized nightshift state as 'suspended'"
fi

# First run marker
: > "$HOME/.local/state/vibranium/first-run"

UpdateSummary "State: created first-run marker file"
