#!/usr/bin/env bash

cp /usr/share/applications/nvim.desktop "$HOME"/.local/share/applications
sed -e '/Terminal/s/true/false/' \
    -e '/^Exec/s/=/=vibranium-cmd-launch-terminal /' \
    -i "$HOME"/.local/share/applications/nvim.desktop

