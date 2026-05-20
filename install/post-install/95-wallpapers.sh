#!/usr/bin/bash

_log_info "Downloading wallpapers"
_log_info "This might take some time"

git clone -q "https://github.com/shvedes/vibranium-wallpapers" ~/.config/vibranium/themes
rm -rf ~/.config/vibranium/themes/.git ~/.config/vibranium/themes/.github
