#!/usr/bin/env bash

RESET=$'\e[0m'
YELLOW=$'\e[0;33m'
N="$(basename "${0%.sh}")"

echo -e "${YELLOW}[MIGRATION $N]${RESET} Installing new dependency: webp-pixbuf-loader"
sudo pacman -S --needed --noconfirm webp-pixbuf-loader
