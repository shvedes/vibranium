#!/bin/bash

# We assume that if the battery is present,
# then most likely it's a laptop with a touchpad.
if vb-cmd-battery-present; then
  cp "$VIBRANIUM/config/hypr/hyprland.conf.d/gestures.conf" \
    ~/.config/hypr/hyprland.conf.d/
fi
