#!/usr/bin/env bash

# no-op
exit 0

ICONS_DIR="$HOME/.local/share/icons"
BIN_DIR="$HOME/.local/bin"
CACHE_DIR="$HOME/.cache"

PAPIRUS_REPO="https://github.com/PapirusDevelopmentTeam/papirus-icon-theme.git"
PAPIRUS_FOLDERS_URL="https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/refs/heads/master/papirus-folders"

spinner_frames=(
  '[=   ]'
  '[ =  ]'
  '[  = ]'
  '[   =]'
)

_spinner() {
  local i=0

  while true; do
    printf "\r\033[K%s Installing icon theme" \
      "${GRAY}${spinner_frames[$i]}${RESET}"

    i=$(((i + 1) % ${#spinner_frames[@]}))
    sleep 0.15
  done
}

cleanup() {
  [[ -n "${PAPIRUS_TMP_DIR:-}" && -d "$PAPIRUS_TMP_DIR" ]] && rm -rf "$PAPIRUS_TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$ICONS_DIR" "$BIN_DIR"

_spinner &
spinner_pid=$!

PAPIRUS_TMP_DIR="$(mktemp -d "$CACHE_DIR/papirus.XXXXXX")"

git clone -q "$PAPIRUS_REPO" "$PAPIRUS_TMP_DIR"
cp -r "$PAPIRUS_TMP_DIR"/Papirus* "$ICONS_DIR"

curl -fsSL "$PAPIRUS_FOLDERS_URL" -o "$BIN_DIR/papirus-folders"
chmod +x "$BIN_DIR/papirus-folders"

cp -r "$VIBRANIUM/extras/icon_theme/Vibranium" "$ICONS_DIR"
ln -sf "$ICONS_DIR" "$HOME/.icons"

kill "$spinner_pid" 2> /dev/null
wait "$spinner_pid" 2> /dev/null

printf "\r\033[K%s[INFO]%s Icons installed\n" "$CYAN" "$RESET"
