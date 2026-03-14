#!/usr/bin/env bash

if [[ -f /tmp/vb-uncomment-mangohud ]]; then
  sed -i '/MANGOHUD_/s/^# //' "$HOME/.config/vibranium/environment"
  rm /tmp/vb-uncomment-mangohud
  UpdateSummary "cfgs: uncommented the MANGOHUD_* line in ~/.config/vibranium/environment"
fi
