#!/usr/bin/env bash

if term::ask_yes_no N "Would you like to install gaming packages?"; then
  mapfile -t packages < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-gaming.pkgs")
  InstallPackages "${packages[@]}"
fi

touch /tmp/vb-uncomment-mangohud
