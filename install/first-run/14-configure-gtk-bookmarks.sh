#!/usr/bin/env bash

# Automatically populate sidebar menu (bookmarks)
# with the default XDG folders.

file="$XDG_CONFIG_HOME/user-dirs.dirs"

if [[ ! "$file" ]]; then
  msg="$file does not exists! No default folder & bookmarks were created.\n"

  if command -v xdg-user-dir >/dev/null; then
    msg=+"To fix, run 'systemctl --user enable --now xdg-user-dirs'"
  else
    msg+="To fix, install xdg-user-dirs and run\n"
    msg=+"'systemctl --user start xdg-user-dirs'"
  fi

  notify-send -r $RANDOM -t 30000 -u critical \
    "Vibranium - First Run Hooks" "$msg"
fi

_parse_user_dirs() {
  while IFS='=' read -r key value; do
    [[ $key == XDG_*_DIR ]] || continue

    value=${value#\"}
    value=${value%\"}
    value=${value/\$HOME/$HOME}

    echo "file://$value"
  done <"$file"
}

mkdir -p "$XDG_CONFIG_HOME/gtk-3.0"
_parse_user_dirs >"$XDG_CONFIG_HOME/gtk-3.0/bookmarks"
