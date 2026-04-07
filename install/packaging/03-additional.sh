#!/usr/bin/env bash

packages=()

printf "%s[>>>>]%s Additional packages (space-separated, keep empty to skip): %s" "$CYAN" "$RESET" "$YELLOW"
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
