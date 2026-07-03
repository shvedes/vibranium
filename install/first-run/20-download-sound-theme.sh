#!/bin/bash

# To avoid depending on another package for a single file,
# we can simply download that file directly from the source.

DIR="$XDG_DATA_HOME/sounds/Vibranium/stereo"
LINK="https://github.com/ubuntu/yaru/raw/refs/heads/master/sounds/src/stereo/audio-volume-change.oga"
FILE="$DIR/audio-volume-change.oga"

_download() {
    until ping -q -c1 github.com &>/dev/null; do
        sleep 5
    done
    mkdir -p "$DIR"
    curl -fsSL -4 "$LINK" -o "$FILE"
}

if ping -q -c1 github.com &>/dev/null; then
    mkdir -p "$DIR"
    curl -fsSL -4 "$LINK" -o "$FILE"
else
    ( _download ) &
    disown
fi
