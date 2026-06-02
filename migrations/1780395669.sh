#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

cat >> "$XDG_CONFIG_HOME/vibranium/settings.advanced" <<'EOF'

# Launcher keywords: special words recognised in the rofi search bar.
# Each entry has the form "keyword:action", where action is eval'd as a
# shell command. Both inline expressions and function names work:
#
#   "hello:notify-send Hello"
#   "date:notify-send \"\$(date)\""   # escape $ to expand at trigger time, not at source time
#   "kernel:_show_kernel_version"     # function defined in settings.functions
#
# Functions can be defined here (before the array) or in the
# ~/.config/vibranium/settings.functions (preferred way).
# The latter is being sourced by exec scripts that use it.

vb_launcher_keywords=(
  "date:_vb_kw_date"
  "updates:_check_updates"
  "stopify:app2unit -- spotify"
)
EOF

cp "$VIBRANIUM/config/vibranium/settings.functions" "$XDG_CONFIG_HOME/vibranium"
