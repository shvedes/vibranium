#!/usr/bin/env bash

mkdir -p "$HOME/.config/fastfetch"
ln -sf "$VIBRANIUM/config/fastfetch/config.jsonc" \
	"$HOME/.config/fastfetch/config.jsonc"
