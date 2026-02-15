#!/usr/bin/env bash

_parse_user_dirs() {
    local file="$XDG_CONFIG_HOME/user-dirs.dirs"

    [ -f "$file" ] || return 1

    while IFS='=' read -r key value; do
        [[ $key == XDG_*_DIR ]] || continue

        value=${value#\"}
        value=${value%\"}
        value=${value/\$HOME/$HOME}

        echo "file://$value"
    done < "$file"
}

_parse_user_dirs > "$XDG_CONFIG_HOME/gtk-3.0/bookmarks"
