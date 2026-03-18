#!/usr/bin/env bash

InstallPackages rust

_log_info "Compiling additional utilities"
cd "$VIBRANIUM/contrib/vb-cmd-edit-wm-config"
bash build.sh

sudo pacman -Rnsc --noconfirm rust &> /dev/null &
