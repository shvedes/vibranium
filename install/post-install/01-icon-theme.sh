#!/usr/bin/env bash

ICONS_DIR="$HOME/.local/share/icons"
VB_ICONS="$VIBRANIUM/extras/icons/Vibranium"

mkdir -p "$ICONS_DIR"

helpers::copy "$VB_ICONS" "$ICONS_DIR/${VB_ICONS##*/}"

# Compatibility workaround
helpers::symlink "$ICONS_DIR" "$HOME/.icons"
