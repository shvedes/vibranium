#!/usr/bin/env bash

mapfile -t packages < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-base.pkgs")

if [[ "$CHASSIS_TYPE" != vm ]]; then
  packages+=(
    gpu-screen-recorder bluez bluez-utils
    bluetui hyprsunset hyprpaper ddcutil
    wireless-regdb
  )
else
  _log_info "Running in a VM: excluding hardware-specific packages"
fi

InstallPackages "${packages[@]}"

unset packages

if term::ask_yes_no Y "Enable MTP (Android / Digital Cameras)?"; then
  packages+=(gvfs-mtp)
fi

if ((${#packages[@]} > 0)); then
  InstallPackages "${packages[@]}"
fi
