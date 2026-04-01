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

  # The reason behind this is that when screen locks in a VM (tested only in QEMU),
  # CPU usage spikes almost to 100% and stays there until the unlock.
  printf "# Screen lock isn't available inside of a VM.\n" >>"$hypr_binds"
  printf "unbind = CTRL ALT, L" >>"$hypr_binds"

  UpdateSummary "VM environment: disabled Hyprland animations"
  UpdateSummary "VM environment: removed Bluetooth application and Waybar module"
  UpdateSummary "VM environment: removed night light Waybar module"
fi
