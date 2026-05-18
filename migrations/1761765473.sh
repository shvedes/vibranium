#!/usr/bin/env bash

grep -q PLAYERCTL "$HOME/.config/vibranium/settings" && {
	sed -i 's/PLAYERCTL/PLAYER/' "$HOME/.config/vibranium/settings"
}
