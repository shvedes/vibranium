#!/usr/bin/env bash

if pacman -Qq wtype &> /dev/null; then
    sudo pacman -Rnsc wtype --noconfirm
fi
