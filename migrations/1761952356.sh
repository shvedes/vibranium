#!/usr/bin/env bash

mkdir -p "$HOME/.config/fastfetch"

if [ -f "$HOME/.config/fastfetch/config.jsonc" ]; then
	mv "$HOME/.config/fastfetch/config.jsonc" \
		"$HOME/.config/fastfetch/config.jsonc.$(date +%y-%m-%d)"
fi

cp "$VIBRANIUM/config/fastfetch/config.jsonc" \
	"$HOME/.config/fastfetch/config.jsonc"
