#!/usr/bin/env bash

waybar_cfg="$HOME/.config/waybar/config.jsonc"
hypr_looknfeel="$HOME/.config/hypr/hyprland.conf.d/look-and-feel.conf"
hypr_binds="$HOME/.config/hypr/hyprland.conf.d/binds.conf"

if [[ "$CHASSIS_TYPE" == vm ]]; then
  _log_info "Setting VM-specific options"

  # Disable animations
  vb-cmd-edit-wm-config "animations:enabled:false" "$hypr_looknfeel"

  # Bluetooth & Wifi
  rm ~/.local/share/applications/bluetui.desktop
  rm ~/.local/share/applications/impala.desktop

  # Bluetooth & Night Light
  sed -i '/\"bluetooth\"/s/\"/\/\/ /' "$waybar_cfg"
  sed -i '/\"custom\/nightshift\"/s/\"/\/\/ /' "$waybar_cfg"

  UpdateSummary "VM environment: disabled Hyprland animations"
  UpdateSummary "VM environment: removed Bluetooth application and Waybar module"
  UpdateSummary "VM environment: removed night light Waybar module"
fi
