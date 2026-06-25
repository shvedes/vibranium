#!/usr/bin/env bash

# We have nothing to connect / listen to in a vm.
if [[ "$CHASSIS_TYPE" == "vm" ]]; then
  command sudo rm -rf /usr/local/bin/vb-android-notify
  command sudo rm -rf /usr/local/bin/vb-battery-alert
  command sudo rm -rf /usr/local/bin/vb-usb-notify
  command sudo rm -rf /etc/udev/rules.d/*
fi

yay -Rnsc yay-debug --noconfirm &>/dev/null || true
yay -Scc --noconfirm &>/dev/null || true
yay -Ycc --noconfirm &>/dev/null || true

mkdir -p "$HOME"/.config/vibranium/{hooks,themed,themes}
