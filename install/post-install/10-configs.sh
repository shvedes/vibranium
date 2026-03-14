#!/usr/bin/env bash

_log_info "Copying configs"

# Everything that is pre-configured.
cp -r "$VIBRANIUM/config/"* "$HOME/.config/"

# Some additional scripts.
# I might move imv auxiliary scripts
# from here eventually. Ideally,
# $VIBRANIUM_PATH is the right place for them.
mkdir -p "$HOME"/.local/bin
cp -r "$VIBRANIUM/extras/local/bin/"* "$HOME/.local/bin"

# Custom / Hidden app menu entries
mkdir -p "$HOME"/.local/share/applications

# Previously I used to symlink all of them, but practically speaking it is
# not a good solution. If the user wants to edit one of them or simply
# *unhide* an entry, it will create git conflicts, which **will**
# lead to further confusion and Vibranium update errors.
cp -r "$VIBRANIUM"/applications/*.desktop "$HOME/.local/share/applications"

# Don't use brace expansion here for the sake of readability.
cp -r "$VIBRANIUM"/applications/custom/*.desktop "$HOME/.local/share/applications"
cp -r "$VIBRANIUM"/applications/hidden/*.desktop "$HOME/.local/share/applications"
