#!/usr/bin/env bash

mapfile -t packages < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-base.pkgs")
mapfile -t fonts < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-fonts.pkgs")

packages+=(${fonts[@]})

if [[ "$CHASSIS_TYPE" != vm ]]; then
  packages+=(
    gpu-screen-recorder bluez bluez-utils
    bluetui hyprsunset hyprpaper ddcutil
    wireless-regdb hyprlock hypridle
  )
else
  _log_info "Running in a VM: excluding hardware-specific packages"
fi

for pkg in "${packages[@]}"; do
  printf "%s\n" "$pkg" >> /tmp/vibranium.packages
done
