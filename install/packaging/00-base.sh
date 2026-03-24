#!/usr/bin/env bash

mapfile -t packages < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-base.pkgs")
mapfile -t fonts < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-fonts.pkgs")

packages+=(${fonts[@]})

if [[ "$CHASSIS_TYPE" != vm ]]; then
  packages+=(
    gpu-screen-recorder bluez bluez-utils
    bluetui hyprsunset ddcutil wireless-regdb
    hyprlock hypridle awww-git
  )
else
  _log_info "Running in a VM: excluding hardware-specific packages"
fi

rm -f /tmp/vibranium.packages

for pkg in "${packages[@]}"; do
  printf "%s\n" "$pkg" >>/tmp/vibranium.packages
done
