#!/usr/bin/env bash

# To avoid depending on another package for a single file,
# we can simply download that file directly from the source.

DIR="$XDG_DATA_HOME/sounds/Vibranium/stereo"
LINK="https://github.com/ubuntu/yaru/raw/refs/heads/master/sounds/src/stereo/audio-volume-change.oga"
FILE="$DIR/audio-volume-change.oga"

mkdir -p "$DIR"
wget -q -4 "$LINK" -O "$FILE"
