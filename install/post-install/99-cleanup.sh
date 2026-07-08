#!/bin/bash

# We have nothing to connect / listen to in a vm.
if [[ "$CHASSIS_TYPE" == "vm" ]]; then
  command sudo rm -rf /etc/udev/rules.d/*
elelif [[ "$CHASSIS_TYPE" == "desktop" ]]; then
  command sudo rm -rf /etc/udev/rules.d/10-battery-alert.rules
fi

yay -Rnsc yay-debug --noconfirm &>/dev/null || true
yay -Scc --noconfirm &>/dev/null || true
yay -Ycc --noconfirm &>/dev/null || true

mkdir -p "$HOME"/.config/vibranium/{hooks,themed,themes}
