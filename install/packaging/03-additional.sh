#!/bin/bash

packages=()
additional_input=""

trap 'printf "%s" "$RS"' INT

term::enable_input
term::prompt_line additional_input "${C}[>]${RS} Additional packages (space-separated, empty to skip): ${Y}" || additional_input=""
term::disable_input

printf "%s" "$RS"
trap - INT

read -ra packages <<< "$additional_input"

if ((${#packages[@]} > 0)); then
  for pkg in "${packages[@]}"; do
    printf "%s\n" "$pkg" >> /tmp/vibranium.packages
  done
fi
