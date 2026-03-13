#!/usr/bin/env bash

packages=()

if term::ask_yes_no Y "Install optional but not mandatory packages?"; then
  packages+=(pass wev nwg-look)
fi

if term::ask_yes_no Y "Install some cursor themes?"; then
  packages+=(apple_cursor bibata-cursor-git xcursor-vanilla-dmz banana-cursor-bin)
fi

if ((${#packages[@]} > 0)); then
  InstallPackages "${packages[@]}"
fi
