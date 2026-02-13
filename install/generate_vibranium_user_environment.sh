#!/usr/bin/env bash

cat <<EOF > "$HOME/.config/vibranium/environment"
# vim:ft=bash
# Place your environment variables here.
# The text below is just an example. Feel free to delete or change it
# All changes are applied only after re-login!

export SUDO_PROMPT="\$(tput setaf 1)\$(tput bold)[sudo]\$(tput sgr0) Password for \$USER: "

# Set your default editor
# This could be nvim, nano, emacs, kate or whatever you want
export EDITOR="nvim"
export SYSTEMD_EDITOR="\$EDITOR"
export MANPAGER="\$EDITOR +Man!"

# You can also reassign the default folders for userspace package managers.
# Golang, for example, likes to create its home folder directly right in \$HOME,
# which can sometimes be annoying. You can reassign this directory to anywhere you want.
# export GOPATH="\$XDG_DATA_HOME/go"
# export CARGO_HOME="\$XDG_DATA_HOME/cargo"

# And then you can add the application to \$PATH in this way
# export PATH="\$HOME/.local/bin:\$VIBRANIUM_PATH:\$GOPATH/bin:\$PATH"

# If you actively use mangohud, you can specify its entire configuration in a single variable,
# instead of a special file in the root folder of each game:
# export MANGOHUD_CONFIG="fps_only,alpha=0.3,background_alpha=0,text_color=ffffff,font_size=18"

# If you are a pass user (https://www.passwordstore.org/), you can specify a specific folder that pass will use to look for passwords. For example:
# export PASSWORD_STORE_DIR="\$XDG_DATA_HOME/password-store"

EOF
