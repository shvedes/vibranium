#!/usr/bin/env bash

packages=()

if term::ask_yes_no Y "Would you like to install optional but not mandatory packages?"; then
    packages+=(pass wev nwg-look)
fi

if (( ${#packages[@]} > 0 )); then
    InstallPackages "${packages[@]}"
fi

