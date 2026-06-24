#!/usr/bin/env bash

ICONS_DIR="$HOME/.local/share/icons"
VB_ICONS="$VIBRANIUM/extras/icons/Vibranium"

mkdir -p "$ICONS_DIR"

vb::copy "$VB_ICONS" "$ICONS_DIR/$(basename "$VB_ICONS")"

# Compatibility workaround
vb::symlink "$ICONS_DIR" "$HOME/.icons"
