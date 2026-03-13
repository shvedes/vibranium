#!/usr/bin/env bash

CURRENT_BRANCH="$(git -C "$VIBRANIUM" branch --show-current)"
STATE_FILE="$HOME/.local/state/vibranium/update.channel"

if [[ "$CURRENT_BRANCH" =~ ^v[09]\.[09]\.[09]$ ]]; then
  printf "%s" "release" > "$STATE_FILE"

elif [[ "$CURRENT_BRANCH" == "dev" ]]; then
  printf "%s" "dev" > "$STATE_FILE"
else
  if [[ "$CURRENT_BRANCH" == "master" ]]; then
    printf "%s" "upstream" > "$STATE_FILE"
  else
    printf "%s" "$CURRENT_BRANCH" > "$STATE_FILE"
  fi
fi
