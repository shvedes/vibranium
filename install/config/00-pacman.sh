#!/usr/bin/env bash

PACMAN_CONF="/etc/pacman.conf"
MAKEPKG_CONF="/etc/makepkg.conf"
VIBRANIUM="$HOME/.local/share/vibranium"

# Enable multilib repository
grep -qE '^\[multilib\]' "$PACMAN_CONF" ||
  sudo sed -Ei '/\[multilib\]/,/^$/s/^#//' "$PACMAN_CONF"
sudo sed -i '/^#NoExtract/ s/^#//' "$PACMAN_CONF"

# Use colorized output by default
grep -q '^Color' "$PACMAN_CONF" ||
  sudo sed -Ei 's/^\s*#?Color/Color/' "$PACMAN_CONF"

# Use verbose package list by default
grep -q '^VerbosePkgLists' "$PACMAN_CONF" ||
  sudo sed -Ei 's/^\s*#?VerbosePkgLists/VerbosePkgLists/' "$PACMAN_CONF"

# Use parallel downloads (speeds up download time)
grep -q '^ParallelDownloads = 10' "$PACMAN_CONF" ||
  sudo sed -Ei 's/^\s*#?ParallelDownloads.*/ParallelDownloads = 10/' "$PACMAN_CONF"

# Remove the default wallpaper plugin, which works only in XFCE
# It will be replaced with the vibranium script
sudo sed -i '/^NoExtract/ s|$| usr/lib/thunarx-3/thunar-wallpaper-plugin.so|' "$PACMAN_CONF"
sudo rm -f /usr/lib/thunarx-3/thunar-wallpaper-plugin.so

# Always compile AUR packages for native CPU microarchitecture
grep -q '\-march=native' "$MAKEPKG_CONF" ||
  sudo sed -Ei 's/-march=x86-64/-march=native/' "$MAKEPKG_CONF"

# Do not install debug packages
grep -Eq '^OPTIONS=.*\bdebug\b' "$MAKEPKG_CONF" &&
  sudo sed -Ei '/^OPTIONS=/ s/(^|[[:space:]])!?debug(\b)/\1!debug\2/' "$MAKEPKG_CONF"

sudo pacman -Sy --noconfirm &> /dev/null

UpdateSummary "pacman.conf: enabled colorized output"
UpdateSummary "pacman.conf: enabled multilib repository"
UpdateSummary "pacman.conf: enabled verbose packages list"
UpdateSummary "pacman.conf: enabled and increased parallel downloads to 10"
UpdateSummary "pacman.conf: added thunar's wallpaper plugin .so file to NoExtract list"
UpdateSummary "makepkg.conf: set -march to 'native'"
UpdateSummary "makepkg.conf: <pkg>-debug is disabled by default"
