#!/usr/bin/env bash

declare -A LINKS=(
  # It's probably not the best practice...
  ["$HOME/.local/share/vibranium/default/uwsm/env"]="$HOME/.config/uwsm/env"
)

for src in "${!LINKS[@]}"; do
  ln -sf "$src" "${LINKS[$src]}" > /dev/null
done

UpdateSummary "Configuration: created UWSM environment symlink from Vibranium defaults"
