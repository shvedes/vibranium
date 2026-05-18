#!/usr/bin/env bash

sed -i 's/vb-webapp-launch/vb-launch-webapp/g' ~/.local/share/applications/PWA*.desktop 2>/dev/null
sed -i 's/xdg-terminal-exec/vb-launch-tui/g' ~/.config/waybar/modules/*.jsonc 2>/dev/null
sed -i 's/xdg-terminal-exec/vb-launch-tui/g' ~/.local/share/applications/*.desktop 2>/dev/null
