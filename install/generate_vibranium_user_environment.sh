#!/usr/bin/env bash

cat <<EOF > "$HOME/.config/vibranium/environment"
# vim:ft=bash
# Place your environment variables here

export EDITOR="nvim"
export SYSTEMD_EDITOR="$EDITOR"
export MANPAGER="$EDITOR +Man!"

EOF
