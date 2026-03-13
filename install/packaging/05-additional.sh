#!/usr/bin/env bash

packages=()

if term::ask_yes_no Y "Would you like to install optional packages?"; then
    packages+=(pass)
fi

if (( ${#packages[@]} > 0 )); then
    InstallPackages "${packages[@]}"
fi

