#!/usr/bin/env bash

yay -Rnsc yay-debug --noconfirm &> /dev/null || true
yay -Scc --noconfirm &> /dev/null
yay -Ycc --noconfirm &> /dev/null

mkdir -p "$HOME"/.config/vibranium/{theme,startup,shutdown}
mkdir -p "$HOME"/.local/state/vibranium

UpdateSummary "Package manager: removed yay-debug package"
UpdateSummary "Package manager: cleaned yay build files and cache"
