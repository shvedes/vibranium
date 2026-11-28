#!/bin/bash

# Keep existing Vibranium shortcuts visible when another browser is installed.
applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
for entry in "$applications"/PWA\ -\ *.desktop; do
  [[ -f $entry && ! -L $entry ]] || continue
  if rg -q '^Exec=vb-launch-webapp ' "$entry" && rg -qx 'TryExec=chromium' "$entry"; then
    sed -i 's/^TryExec=chromium$/TryExec=vb-launch-webapp/' "$entry" || exit 1
  fi
done
exit 0
