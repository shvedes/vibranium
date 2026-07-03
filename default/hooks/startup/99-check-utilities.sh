#!/bin/bash

if ! command -v vb-cmd-edit-wm-config >/dev/null; then
  : > "$VIBRANIUM_STATE/errors_found"

  notify-send -u critical -r 1 -t 360000 "Vibranium" \
  "Could not find required Vibranium utilities!
Did previous Vibranium update go bad?

Open the terminal and type <b>vibranium-healthcheck</b> to fix it."
fi
