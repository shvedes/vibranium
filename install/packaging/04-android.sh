#!/usr/bin/env bash

if [[ "$CHASSIS_TYPE" == vm ]]; then
  exit 0
fi

packages=()

if term::ask_yes_no N "Are you an Android user?"; then
  if term::ask_yes_no Y "Would you like to have MTP support in the file manager?"; then
    packages+=(gvfs-mtp)
  fi

  if term::ask_yes_no Y "Would you like to have adb / fastboot tools?"; then
    packages+=(android-tools)
  fi

  for pkg in "${packages[@]}"; do
    printf "%s\n" "$pkg" >> /tmp/vibranium.packages
  done
fi
