#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

cat >> "$XDG_CONFIG_HOME/waybar/style.css" << 'EOF'

#bluetooth, #bluetooth.disabled, #bluetooth.off {
  opacity: 0.5
}

#bluetooth.connected {
  opacity: 1
}
EOF

# Remove if needed.
echo "${GREEN}[MIGRATION|$SELF]${RESET} Message"
