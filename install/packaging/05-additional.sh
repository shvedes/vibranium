#!/usr/bin/env bash

packages=()
user_pkgs=()

if term::ask_yes_no Y "Install optional but not mandatory packages?"; then
  packages+=(wev nwg-look)
fi

if term::ask_yes_no Y "Install some cursor themes?"; then
  packages+=(apple_cursor bibata-cursor-git xcursor-vanilla-dmz banana-cursor-bin)
fi

if term::ask_yes_no Y "Any additional packages you want to install?"; then
  printf "%s[>>>>]%s Enter packages (space-separated): %s" "$CYAN" "$RESET" "$YELLOW"
  trap 'printf "%s" "$RESET"' INT

  # Handle input
  term::enable_input
  read -ra user_pkgs
  term::disable_input

  # Restore text color
  printf "%s" "$RESET"
  trap - INT
fi

if ((${#packages[@]} > 0)); then
  InstallPackages "${packages[@]}"
fi

if ((${#user_pkgs[@]} > 0)); then
  InstallPackages --verify "${user_pkgs[@]}"
fi
