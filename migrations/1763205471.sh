#!/usr/bin/env bash

sed -i '/current/d' "$HOME/.config/waybar/style.css"
systemctl --user restart waybar
