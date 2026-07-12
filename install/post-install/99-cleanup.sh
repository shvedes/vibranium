#!/bin/bash

# We have nothing to connect / listen to in a vm.
if [[ "$CHASSIS_TYPE" == "vm" ]]; then
  sudo rm -rf /etc/udev/rules.d/*
elif [[ "$CHASSIS_TYPE" == "desktop" ]]; then
  sudo rm -f /etc/udev/rules.d/10-battery-alert.rules
  sudo rm -f /etc/udev/rules.d/10-power-profile.rules
fi

yay -Rnsc yay-debug --noconfirm &>/dev/null || true
yay -Scc --noconfirm &>/dev/null || true
yay -Ycc --noconfirm &>/dev/null || true
