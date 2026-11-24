#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "launcher-keys-live" "delete confirmation keeps the launcher cursor in place"

if ! command -v qs >/dev/null 2>&1; then
  t_block "qs is not on PATH"
fi
if [[ $(systemctl --user is-active vibranium-shell 2>/dev/null) != active ]]; then
  t_block "vibranium-shell.service is not active"
fi

p() { qs -p "$VIBRANIUM_DIR/shell" ipc call appLauncher "$@"; }

trap 'p close >/dev/null 2>&1' EXIT
for ((attempt = 0; attempt < 30; attempt++)); do
  p open >/dev/null
  result=$(p debugConfirmNavigation)
  [[ $result == \{* ]] && break
  sleep 0.1
done

t_status "Tab, Shift-Tab and arrows are accepted without moving the cursor or closing confirmation" 0 \
  python3 -c '
import json
import sys

probe = json.loads(sys.argv[1])
index = probe["index"]
keys = ("Tab", "Shift-Tab", "Backtab", "Up", "Down", "Left", "Right")
results = probe["results"]
assert index >= 0 and len(results) == len(keys), probe
for key, result in zip(keys, results):
    assert result == {"accepted": True, "index": index, "open": True}, (key, result)
' "$result"
