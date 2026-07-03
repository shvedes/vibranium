#!/bin/bash

helpers::log::info "Installing MPV theme"
git clone -q https://github.com/noelsimbolon/mpv-config "$HOME/.config/mpv"
