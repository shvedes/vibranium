#!/usr/bin/env bash

if [[ -f /tmp/vb-uncomment-mangohud ]]; then
    sed -i '/MANGOHUD_/s/^# //' "$HOME/.config/vibranium/environment"
    rm /tmp/vb-uncomment-mangohud
fi

