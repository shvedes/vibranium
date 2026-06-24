#!/usr/bin/env bash

PACMAN_CONF="/etc/pacman.conf"
MAKEPKG_CONF="/etc/makepkg.conf"

# Enable multilib repository
grep -qE '^\[multilib\]' "$PACMAN_CONF" ||
  vb::sed "$PACMAN_CONF" -E '/\[multilib\]/,/^$/s/^#//'
vb::sed "$PACMAN_CONF" '/^#NoExtract/ s/^#//'

# Use colorized output by default
grep -q '^Color' "$PACMAN_CONF" ||
  vb::sed "$PACMAN_CONF" -E 's/^\s*#?Color/Color/'

# Use verbose package list by default
grep -q '^VerbosePkgLists' "$PACMAN_CONF" ||
  vb::sed "$PACMAN_CONF" -E 's/^\s*#?VerbosePkgLists/VerbosePkgLists/'

# Use parallel downloads (speeds up download time)
grep -q '^ParallelDownloads = 10' "$PACMAN_CONF" ||
  vb::sed "$PACMAN_CONF" -E 's/^\s*#?ParallelDownloads.*/ParallelDownloads = 10/'

# Remove the default wallpaper plugin, which works only in XFCE.
# It will be replaced with the vibranium script.
vb::sed "$PACMAN_CONF" '/^NoExtract/ s|$| usr/lib/thunarx-3/thunar-wallpaper-plugin.so|'

# Always compile AUR packages for native CPU microarchitecture
grep -q '\-march=native' "$MAKEPKG_CONF" ||
  vb::sed "$MAKEPKG_CONF" -E 's/-march=x86-64/-march=native/'

# Do not install debug packages
grep -Eq '^OPTIONS=.*\bdebug\b' "$MAKEPKG_CONF" &&
  vb::sed "$MAKEPKG_CONF" -E '/^OPTIONS=/ s/(^|[[:space:]])!?debug(\b)/\1!debug\2/'

sudo pacman -Sy --noconfirm &> /dev/null
