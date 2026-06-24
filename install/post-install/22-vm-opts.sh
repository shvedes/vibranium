#!/usr/bin/env bash

waybar_cfg="$HOME/.config/waybar/config.jsonc"

if [[ "$CHASSIS_TYPE" == vm ]]; then
  helpers::log::info "Setting VM-specific options"

  # Bluetooth & Wifi
  helpers::remove "$HOME/.local/share/applications/bluetui.desktop"
  helpers::remove "$HOME/.local/share/applications/impala.desktop"

  # Bluetooth & Night Light
  helpers::sed "$waybar_cfg" '/\"bluetooth\"/s/\"/\/\/ /'
  helpers::sed "$waybar_cfg" '/\"custom\/nightshift\"/s/\"/\/\/ /'
fi
