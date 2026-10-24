#!/bin/bash

PACMAN_CONF="/etc/pacman.conf"

helpers::log::info "Configuring pacman"

grep -qE '^\[multilib\]' "$PACMAN_CONF" ||
	helpers::sed "$PACMAN_CONF" -E '/\[multilib\]/,/^$/s/^#//'

helpers::sed "$PACMAN_CONF" '/^#NoExtract/ s/^#//'
helpers::sed "$PACMAN_CONF" '/^NoExtract/ s|$| usr/lib/thunarx-3/thunar-wallpaper-plugin.so|'

sudo pacman -Syu --noconfirm
