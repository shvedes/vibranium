#!/bin/bash

# The icon theme itself is rendered by the shell (shell/common/theme/Icons.qml).
# Only the search path is seeded here: the cursor helpers read ~/.icons as a
# theme location, so a link to the user icon dir keeps that lookup valid.
ICONS_DIR="$HOME/.local/share/icons"

mkdir -p "$ICONS_DIR"

helpers::symlink "$ICONS_DIR" "$HOME/.icons"
