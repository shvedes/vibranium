#!/usr/bin/env bash

if [[ -f /tmp/vibranium-remove-spicetify ]]; then
  sudo rm /usr/local/bin/patch-spotify
  sudo rm /etc/pacman.d/hooks/70-spotify.hook
  sudo rm /etc/pacman.d/hooks/80-spotify.hook
fi

if [[ -f /tmp/vibranium-remove-vencord ]]; then
  sudo rm /usr/local/bin/patch-discord
  sudo rm /etc/pacman.d/hooks/80-discord.hook
fi

yay -Rnsc yay-debug --noconfirm &>/dev/null || true
yay -Scc --noconfirm &>/dev/null
yay -Ycc --noconfirm &>/dev/null

mkdir -p "$HOME"/.config/vibranium/{theme,startup,shutdown}

UpdateSummary "Package manager: removed yay-debug package"
UpdateSummary "Package manager: cleaned yay build files and cache"
