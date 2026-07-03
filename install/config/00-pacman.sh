#!/bin/bash

PACMAN_CONF="/etc/pacman.conf"
MAKEPKG_CONF="/etc/makepkg.conf"

helpers::log::info "Configuring package manager"

grep -qE '^\[multilib\]' "$PACMAN_CONF" ||
  helpers::sed "$PACMAN_CONF" -E '/\[multilib\]/,/^$/s/^#//'

grep -q '^VerbosePkgLists' "$PACMAN_CONF" ||
  helpers::sed "$PACMAN_CONF" -E 's/^\s*#?VerbosePkgLists/VerbosePkgLists/'

grep -q '^ParallelDownloads = 10' "$PACMAN_CONF" ||
  helpers::sed "$PACMAN_CONF" -E 's/^\s*#?ParallelDownloads.*/ParallelDownloads = 10/'

helpers::sed "$PACMAN_CONF" '/^#NoExtract/ s/^#//'
helpers::sed "$PACMAN_CONF" '/^NoExtract/ s|$| usr/lib/thunarx-3/thunar-wallpaper-plugin.so|'

grep -q '\-march=native' "$MAKEPKG_CONF" ||
  helpers::sed "$MAKEPKG_CONF" -E 's/-march=x86-64/-march=native/'

grep -Eq '^OPTIONS=.*\bdebug\b' "$MAKEPKG_CONF" &&
  helpers::sed "$MAKEPKG_CONF" -E '/^OPTIONS=/ s/(^|[[:space:]])!?debug(\b)/\1!debug\2/'

sudo pacman -Sy --noconfirm &> /dev/null
