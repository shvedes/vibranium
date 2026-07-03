#!/bin/bash

# Automatically populate sidebar menu (bookmarks)
# with the default XDG folders.

file="$XDG_CONFIG_HOME/user-dirs.dirs"

if [[ ! -f "$file" ]]; then
  msg="$file does not exist! No default folders & bookmarks were created.\n"
  msg+="To fix, run 'systemctl --user enable --now xdg-user-dirs'"
  notify-send -r $RANDOM -t 30000 -u critical "Vibranium - First Run Hooks" "$msg"
  exit 1
fi

_parse_user_dirs() {
  while IFS='=' read -r key value; do
    [[ $key == XDG_*_DIR ]] || continue

    value=${value#\"}
    value=${value%\"}
    value=${value//\$HOME/$HOME}

    echo "file://$value"
  done <"$file"
}

mapfile -t _xdg_dirs < <(_parse_user_dirs)

mkdir -p "$XDG_CONFIG_HOME/gtk-3.0"
printf '%s\n' "${_xdg_dirs[@]}" \
  >"$XDG_CONFIG_HOME/gtk-3.0/bookmarks"

_qt_shortcuts="file:"
for _dir in "${_xdg_dirs[@]}"; do
  _qt_shortcuts+=", $_dir"
done

sed -i "s|^shortcuts=.*|shortcuts=$_qt_shortcuts|" \
  "$XDG_CONFIG_HOME/QtProject.conf"
