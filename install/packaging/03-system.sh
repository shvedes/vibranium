#!/usr/bin/env bash

packages=()

if term::ask_yes_no N "Install additional filesystem utilities? (optional)"; then
  packages+=(dosfstools exfatprogs mtools)
  UpdateSummary "User choice: installed filesystem utilities (${packages[@]})"
  InstallPackages "${packages[@]}"
fi
