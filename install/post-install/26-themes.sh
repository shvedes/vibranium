#!/bin/bash

if ! term::ask_yes_no N "Would you like to install additional themes?"; then
  exit 0
fi

DEST="$HOME/.config/vibranium/themes"
PREFIX="vibranium-theme-"

repos=$(curl -sf "https://api.github.com/users/shvedes/repos?per_page=100" \
  | grep -oP '"name":\s*"\K[^"]+' \
  | grep "^$PREFIX" \
  | sort)

if [[ -z $repos ]]; then
  log Warn "No themes found"
  exit 0
fi

mapfile -t themes <<< "$repos"
total=${#themes[@]}
current=0
installed=0

spinner_frames=(
  '[=   ]'
  '[ =  ]'
  '[  = ]'
  '[   =]'
)

frame_file="/tmp/${0##*/}.frame"
tag_file="/tmp/${0##*/}.tag"

echo 0 > "$frame_file"

_spinner() {
  local i
  i=$(<"$2")

  while true; do
    local tag
    tag=$(<"$4")
    printf "\r\033[K%s Installing %s%s [%d/%d]" \
      "${GRAY}${spinner_frames[$i]}${RESET}" \
      "${CYAN}$1${RESET}" "$tag" "$3" "$5"

    echo "$i" > "$2"
    i=$(((i + 1) % ${#spinner_frames[@]}))
    sleep 0.15
  done
}

_stop_spinner() {
  kill "$spinner_pid" 2> /dev/null
  wait "$spinner_pid" 2> /dev/null
}

mkdir -p "$DEST"

for theme in "${themes[@]}"; do
  ((current++))
  name="${theme#$PREFIX}"
  display="${name^}"
  display="${display/-/ }"

  echo "" > "$tag_file"
  _spinner "$display" "$frame_file" "$current" "$tag_file" "$total" &
  spinner_pid=$!

  if git clone -q "https://github.com/shvedes/$theme" "$DEST/$name" 2> /dev/null; then
    ((installed++))
    echo " -> $DEST/$name" > "$tag_file"
  else
    echo " [FAIL]" > "$tag_file"
  fi

  _stop_spinner
done

rm -f "$frame_file" "$tag_file"

if (( installed == 0 )); then
  printf "\r\e[K%s[THEME]%s No themes installed\n" \
    "$CYAN" "$RESET"
else
  printf "\r\e[K%s[THEME]%s %s%d%s themes installed\n" \
    "$CYAN" "$RESET" "$GREEN" "$installed" "$RESET"
fi
