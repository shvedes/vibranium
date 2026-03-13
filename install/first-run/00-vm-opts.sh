#!/usr/bin/env bash

waybar_cfg="$XDG_CONFIG_HOME/waybar/config.jsonc"

if [[ "$CHASSIS_TYPE" == vm ]]; then
    # Disable animations
    vb-cmd-edit-wm-config "animations:enabled:false" \
        "$XDG_CONFIG_HOME/hypr/hyprland.conf.d/look-and-feel.conf"

    # Bluetooth & Night Light
    rm ~/.local/share/applications/bluetui.desktop
    sed -i '/\"bluetooth\"/s/\"/\/\/ /' "$waybar_cfg"
    sed -i '/\"custom\/nightshift\"/s/\"/\/\/ /' "$waybar_cfg"
    systemctl -q --user restart waybar
fi
