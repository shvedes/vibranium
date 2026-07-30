#!/bin/bash

packages=()

printf "%s[>>>>]%s Additional packages (space-separated, empty to skip): %s" "$C" "$RS" "$Y"
trap 'printf "%s" "$RS"' INT

term::enable_input
read -ra packages
term::disable_input

printf "%s" "$RS"
trap - INT

if ((${#packages[@]} > 0)); then
  for pkg in "${packages[@]}"; do
    printf "%s\n" "$pkg" >>/tmp/vibranium.packages
  done
fi
