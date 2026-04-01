#!/usr/bin/env bash

ICONS_DIR="$HOME/.local/share/icons"
VB_ICONS="$VIBRANIUM/extras/icon_theme/Vibranium"

mkdir -p "$ICONS_DIR"

cp -r "$VB_ICONS" "$ICONS_DIR"

# Compatibility workaround
ln -sf "$ICONS_DIR" "$HOME/.icons"
