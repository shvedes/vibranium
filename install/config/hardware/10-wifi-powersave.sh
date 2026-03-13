#!/usr/bin/env bash

# Source: Omarchy

if vb-cmd-battery-present; then
    cat <<EOF | sudo tee "/etc/udev/rules.d/99-wifi-powersave.rules" > /dev/null
    SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="$HOME/.local/share/vibranium/bin/vb-cmd-wifi-powersave on"
    SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="$HOME/.local/share/vibranium/bin/vb-cmd-wifi-powersave off"
EOF

    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=power_supply
fi
