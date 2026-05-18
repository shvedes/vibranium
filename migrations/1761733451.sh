#!/usr/bin/env bash

if [ -d "$HOME/.config/fastfetch" ]; then
	mv "$HOME/.config/fastfetch" \
		 "$HOME/.config/fastfetch.backup"
fi
cp -r "$VIBRANIUM/config/fastfetch" \
	"$HOME/.config"
