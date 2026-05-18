#!/usr/bin/env bash

if pacman -Qq catfish >/dev/null; then
    sudo pacman -Rnsc --noconfirm catfish
fi
