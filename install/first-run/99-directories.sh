#!/usr/bin/bash
# shellcheck disable=SC2174

mkdir -p -m 700 "${GNUPGHOME:-$XDG_DATA_HOME}/gnupg"
mkdir -p -m 700 "$XDG_DATA_HOME/wget"
