#!/usr/bin/env bash

packages=()

if term::ask_yes_no N "Install additional filesystem utilities?"; then
    packages+=(dosfstools exfatprogs mtools)
    InstallPackages "${packages[@]}"
fi

