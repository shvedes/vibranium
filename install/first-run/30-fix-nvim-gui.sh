#!/usr/bin/env bash

# https://www.reddit.com/r/linuxquestions/comments/t7ze3c/thunar_open_file_in_neovim/
cp /usr/share/applications/nvim.desktop "$HOME"/.local/share/applications
sed -e '/Terminal/s/true/false/' -e '/^Exec/s/=/=xdg-terminal-exec -- /' \
  -i "$HOME"/.local/share/applications/nvim.desktop
