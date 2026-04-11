#!/usr/bin/env bash

STATE_FILE="$HOME/.local/state/vibranium/update.channel"

branch=$(git -C "$VIBRANIUM" symbolic-ref -q --short HEAD)

if [[ -n "$branch" ]]; then
  case "$branch" in
  master)
    state="upstream"
    ;;
  *)
    state="$branch"
    ;;
  esac
else
  state="release"
fi

printf "%s" "$state" >"$STATE_FILE"

UpdateSummary "Configuration: set Vibranium update channel to $CURRENT_BRANCH"
