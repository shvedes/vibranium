#!/usr/bin/env bash

# Source: Omarchy

if [[ "$CHASSIS_TYPE" == vm ]]; then
  exit 0
fi

if vb-hw-battery; then
  helpers::write_file /etc/udev/rules.d/99-wifi-powersave.rules << EOF2
# Laptop specific: toggle Wifi powersave based on charging state
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="$HOME/.local/share/vibranium/bin/vb-cmd-wifi-powersave --on"
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="$HOME/.local/share/vibranium/bin/vb-cmd-wifi-powersave --off"
EOF2
else
  helpers::write_file /etc/udev/rules.d/99-wifi-powersave.rules << EOF2
# Desktop specific: disable Wifi's powersave mode on every boot
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wl*", RUN+="$HOME/.local/share/vibranium/bin/vb-cmd-wifi-powersave --off"
EOF2
fi
