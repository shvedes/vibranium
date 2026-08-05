#!/bin/bash

mapfile -t packages < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-base.pkgs")
mapfile -t fonts < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-fonts.pkgs")

# Keep hardware-detected packages (btrfs, nvme, ntfs, sata)
# added by the hardware phase before this one
mapfile -t hardware < /tmp/vibranium.packages 2> /dev/null || true

packages+=(${fonts[@]})

if [[ "$CHASSIS_TYPE" != vm ]]; then
  packages+=(
    bluez bluez-utils bluetui
    hyprsunset ddcutil wireless-regdb
  )
fi

rm -f /tmp/vibranium.packages

for pkg in "${packages[@]}" "${hardware[@]}"; do
  printf "%s\n" "$pkg" >>/tmp/vibranium.packages
done
