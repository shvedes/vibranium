#!/bin/bash

# Open the nested-row showcase in the running Vibranium shell.
#
# The bundle declares group rows whose children are ordinary page row types -
# toggle, progress, text, select, number and range - at the compact register.
# It writes no settings: every value lives in the menu's runtime state, so the
# page is safe to poke at repeatedly.
#
# Usage:
#   bash tests/shell/demos/nested-rows-showcase.sh
#
# Close it with the usual menu key, or:
#   qs -p "$VIBRANIUM/shell" ipc call menu close

set -u

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VIBRANIUM="$(cd "$_HERE/../../.." && pwd)"
_BUNDLE="$_HERE/nested-rows-showcase.jsonc"

if [[ ! -f $_BUNDLE ]]; then
  printf 'showcase bundle not found: %s\n' "$_BUNDLE" >&2
  exit 1
fi

printf 'opening nested-row showcase: %s\n' "$_BUNDLE"
exec qs -p "$_VIBRANIUM/shell" ipc call menu openFile "$_BUNDLE"
