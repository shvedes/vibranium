#!/usr/bin/env bash

curl -s "https://raw.githubusercontent.com/spicetify/spicetify-themes/refs/heads/master/text/user.css" \
	-o "${XDG_CONFIG_HOME:-$HOME/.config}/spicetify/Themes/text/user.css"
