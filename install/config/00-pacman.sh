#!/usr/bin/env bash

PACMAN_CONF="/etc/pacman.conf"
MAKEPKG_CONF="/etc/makepkg.conf"

# Enable multilib repository
grep -qE '^\[multilib\]' "$PACMAN_CONF" ||
  helpers::sed "$PACMAN_CONF" -E '/\[multilib\]/,/^$/s/^#//'

# Use verbose package list by default
grep -q '^VerbosePkgLists' "$PACMAN_CONF" ||
  helpers::sed "$PACMAN_CONF" -E 's/^\s*#?VerbosePkgLists/VerbosePkgLists/'

# Use parallel downloads (speeds up download time)
grep -q '^ParallelDownloads = 10' "$PACMAN_CONF" ||
  helpers::sed "$PACMAN_CONF" -E 's/^\s*#?ParallelDownloads.*/ParallelDownloads = 10/'

# Remove the default wallpaper plugin, which works only in XFCE.
# It will be replaced with the vibranium script.
helpers::sed "$PACMAN_CONF" '/^#NoExtract/ s/^#//'
helpers::sed "$PACMAN_CONF" '/^NoExtract/ s|$| usr/lib/thunarx-3/thunar-wallpaper-plugin.so|'

# Always compile AUR packages for native CPU microarchitecture
grep -q '\-march=native' "$MAKEPKG_CONF" ||
  helpers::sed "$MAKEPKG_CONF" -E 's/-march=x86-64/-march=native/'

# Do not install debug packages
grep -Eq '^OPTIONS=.*\bdebug\b' "$MAKEPKG_CONF" &&
  helpers::sed "$MAKEPKG_CONF" -E '/^OPTIONS=/ s/(^|[[:space:]])!?debug(\b)/\1!debug\2/'

sudo pacman -Sy --noconfirm &> /dev/null
