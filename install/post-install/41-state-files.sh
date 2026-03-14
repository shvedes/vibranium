#!/usr/bin/env bash

# Initial state for the hyprsunset
printf "suspended" > "$HOME/.local/state/vibranium/nightshift"

# First run marker
: > "$HOME/.local/state/vibranium/first-run"

UpdateSummary "State: initialized nightshift state as 'suspended'"
UpdateSummary "State: created first-run marker file"
