#!/usr/bin/env bash

waybar_cfg="$HOME/.config/waybar/config.jsonc"
hypr_cfg="$HOME/.config/hypr/hyprland.conf.d/look-and-feel.conf"

if [[ "$CHASSIS_TYPE" == vm ]]; then
  # Disable animations
  vb-cmd-edit-wm-config "animations:enabled:false" "$hypr_cfg"

  # Bluetooth & Night Light
  rm ~/.local/share/applications/bluetui.desktop
  sed -i '/\"bluetooth\"/s/\"/\/\/ /' "$waybar_cfg"
  sed -i '/\"custom\/nightshift\"/s/\"/\/\/ /' "$waybar_cfg"
fi
