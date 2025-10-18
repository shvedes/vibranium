#!/usr/bin/env bash

cat <<EOF > "$HOME/.config/zathura/zathurarc"
include ../vibranium/theme/current/zathura
include ../../.local/share/vibranium/defaults/zathurarc

set font "Cascadia Code 9"
EOF
