#!/usr/bin/env bash

DIR="$HOME/.local/share/sounds/Vibranium/stereo"
LINK="https://github.com/ubuntu/yaru/raw/refs/heads/master/sounds/src/stereo/audio-volume-change.oga"
FILE="${DIR}/audio-volume-change.oga"

mkdir -p "$DIR"
wget -q -4 "$LINK" -O "$FILE"

sudo pacman -Rnsc --noconfirm yaru-sound-theme
