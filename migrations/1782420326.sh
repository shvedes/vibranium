#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

comamnd sudo rm -f /etc/udev/rules.d/99-android.rules
command cp "$VIBRANIUM/extras/etc/udev/rules.d/80-android.rules" /etc/udev/rules.d/

if [[ "$CHASSIS_TYPE" != "vm" ]]; then
  command sudo rm -f /etc/udev/rules.d/99-wifi-powersave.rules

  if vb-hw-battery; then
    comamnd sudo rm -f /etc/udev/rules.d/99-vb-battery-alert.rules
    command cp "$VIBRANIUM/extras/etc/udev/rules.d/10-battery-alert.rules" /etc/udev/rules.d/

    sudo tee /etc/udev/rules.d/10-wifi-powersave.rules <<EOF2
# This file was created by Vibranium install scripts.
# #################################################### #
# Laptop specific: toggle Wifi powersave based on charging state
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/usr/bin/su-bridge vb-cmd-wifi-powersave --on"
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/usr/bin/su-bridge vb-cmd-wifi-powersave --off"
EOF2
  else
    sudo tee /etc/udev/rules.d/10-wifi-powersave.rules <<EOF2
# This file was created by Vibranium install scripts.
# #################################################### #
# Desktop specific: disable Wifi's powersave mode on every boot
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wl*", RUN+="/usr/bin/su-bridge vb-cmd-wifi-powersave --off"
EOF2
  fi

  comamnd sudo rm -f /etc/udev/rules.d/99-vb-usb.rules
  command cp "$VIBRANIUM/extras/etc/udev/rules.d/80-usb-pen.rules" /etc/udev/rules.d/
fi

sudo cp "$VIBRANIUM/extras/usr/local/bin/su-bridge" /usr/local/bin/
sudo cp "$VIBRANIUM"/extras/etc/pacman.d/hooks/*.hooks /etc/pacman.d/hooks/
