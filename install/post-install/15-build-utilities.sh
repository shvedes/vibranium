#!/usr/bin/env bash

_log_info "Building Vibranium utilities"

sudo pacman -S --noconfirm rust &>/dev/null

cd "$VIBRANIUM/contrib/vb-cmd-edit-wm-config"
bash build.sh

sudo pacman -Rnsc --noconfirm rust &>/dev/null

UpdateSummary "Compiled and installed vb-cmd-edit-wm-config"
