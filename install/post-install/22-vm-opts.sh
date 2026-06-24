#!/usr/bin/env bash

waybar_cfg="$HOME/.config/waybar/config.jsonc"

if [[ "$CHASSIS_TYPE" == vm ]]; then
  helpers::log::info "Setting VM-specific options"

  # Bluetooth & Wifi
  vb::remove "$HOME/.local/share/applications/bluetui.desktop"
  vb::remove "$HOME/.local/share/applications/impala.desktop"

  # Bluetooth & Night Light
  vb::sed "$waybar_cfg" '/\"bluetooth\"/s/\"/\/\/ /'
  vb::sed "$waybar_cfg" '/\"custom\/nightshift\"/s/\"/\/\/ /'
fi
