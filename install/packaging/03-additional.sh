#!/usr/bin/env bash

packages=()

if ! term::ask_yes_no Y "Any additional packages you want to install?"; then
  exit 0
fi

printf "%s[>>>>]%s Enter packages (including AUR): %s" "$CYAN" "$RESET" "$YELLOW"
trap 'printf "%s" "$RESET"' INT

# Handle input
term::enable_input
read -ra packages
term::disable_input

# Restore text color
printf "%s" "$RESET"
trap - INT

if ((${#packages[@]} > 0)); then
  for pkg in "${packages[@]}"; do
    printf "%s\n" "$pkg" >>/tmp/vibranium.packages
  done
fi
