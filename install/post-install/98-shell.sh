#!/usr/bin/env bash

if term::ask_yes_no Y "Would you like to use fish shell?"; then
  InstallPackages fish
  sudo usermod --shell /usr/bin/fish $USER
  rm -rf "$HOME"/.config/{bash,starship.toml} "$HOME"/.bashrc
else
  InstallPackages starship
  sudo pacman -Rnsc --noconfirm fish &>/dev/null
  rm -rf "$HOME"/.config/fish
fi
