#!/usr/bin/env bash

YELLOW=$'\e[0;33m'
RESET=$'\e[0m'

PACKAGES=(
    # File Roller
    "7zip"
    "arj"
    "bzip3"
    "cdrtools"
    "dpkg" # Debian packages
    "lhasa"
    "lrzip"
    "rpmextract" # RPM packages
    "squashfs-tools"
    "unace"
    "unrar"
    "unzip"
    "zip"

    # Other
    "speedtest-cli"
    "ncdu"
)

printf "%s[VIBRANIUM]%s Installing core components & libraries" "$YELLOW" "$RESET"
sudo pacman -Suy --needed --noconfirm "${PACKAGES[@]}" &>/dev/null
