#!/usr/bin/env bash

packages=()
user_pkgs=()
user_pkgs_present=false

if term::ask_yes_no Y "Install optional but not mandatory packages?"; then
  packages+=(wev nwg-look)
fi

if term::ask_yes_no Y "Install some cursor themes?"; then
  packages+=(apple_cursor bibata-cursor-git xcursor-vanilla-dmz banana-cursor-bin)
fi

if term::ask_yes_no Y "Any additional packages you want to install?"; then
  user_pkgs_present=true
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

if [[ "$user_pkgs_present" == true ]]; then
  packages+=(${user_pkgs[@]})
fi

if ((${#packages[@]} > 0)); then
  if [[ "$user_pkgs_present" == true ]]; then
    InstallPackages --verify "${packages[@]}"
  else
    InstallPackages "${packages[@]}"
  fi
fi
