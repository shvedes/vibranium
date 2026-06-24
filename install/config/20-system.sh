#!/usr/bin/env bash

# pacman hooks
# polkit rule (sudoless mounting)
# v4l loopback (aka virtual camera)
for entry in "$VIBRANIUM"/extras/etc/*; do
  [[ -e "$entry" ]] || continue
  vb::copy "$entry" "/etc/$(basename "$entry")"
done

# Power plug / USB notifications
vb::copy "$VIBRANIUM/extras/etc/udev/rules.d" /etc/udev/rules.d

# Auxiliary scripts (executed by the udev)
local_bin_files=()
for entry in "$VIBRANIUM"/extras/usr/local/bin/*; do
  [[ -e "$entry" ]] || continue
  dest="/usr/local/bin/$(basename "$entry")"
  vb::copy "$entry" "$dest"
  local_bin_files+=("$dest")
done

for file in "${local_bin_files[@]}"; do
  vb::sed "$file" "s/user_placeholder/$USER/g"
done
