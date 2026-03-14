#!/usr/bin/env bash

packages=()

if term::ask_yes_no N "Install additional filesystem utilities? (optional)"; then
  UpdateSummary "User choice: installed filesystem utilities (${packages[@]})"
  packages+=(dosfstools exfatprogs mtools)
  InstallPackages "${packages[@]}"
fi
