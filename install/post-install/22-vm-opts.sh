#!/bin/bash

waybar_cfg="$HOME/.config/waybar/config.jsonc"

if [[ "$CHASSIS_TYPE" == vm ]]; then
  helpers::log::info "Setting VM-specific options"

  helpers::remove "$HOME/.local/share/applications/bluetui.desktop"
  helpers::remove "$HOME/.local/share/applications/impala.desktop"

  helpers::sed "$waybar_cfg" '/\"bluetooth\"/s/\"/\/\/ /'
  helpers::sed "$waybar_cfg" '/\"custom\/nightshift\"/s/\"/\/\/ /'
fi
