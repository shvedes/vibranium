#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'

SELF="${0##*/}"

PKG_NAME="$(pacman -Q hyprland 2>/dev/null | awk '{print $1}')"
PKG_VER="$(pacman -Q hyprland 2>/dev/null | awk '{print $2}')"

# Skip forced update on git builds
if [[ "$PKG_NAME" == *-git ]] || [[ "$PKG_VER" =~ \.r[0-9]+\.[g]?[a-f0-9]+ ]]; then
  exit 0
fi

if ! [[ "$PKG_VER" =~ ^0\.55(\.|$) ]]; then
  echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} Found outdated Hyprland version"
  echo "${GREEN}[MIGRATION|${SELF/.sh/}]${RESET} Full system update required"

  sudo pacman -Suy --noconfirm
fi
