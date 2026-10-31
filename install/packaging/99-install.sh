#!/bin/bash

packages=()
while IFS= read -r package; do
  if [[ -z "$package" || "$package" == \#* ]]; then
    continue
  fi
  packages+=("$package")
done < /tmp/vibranium.packages

if ((${#packages[@]} > 0)); then
  yay -S --noconfirm --needed "${packages[@]}"
fi
