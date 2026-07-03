#!/bin/bash

if ! term::ask_yes_no N "Would you like to install additional themes?"; then
  exit 0
fi

URL="https://github.com/shvedes/vibranium-theme"
DEST="$HOME/.config/vibranium/themes"
THEMES=(
  deep-forest
  kihciahken
  evergarden
  ristretto
  biscuit
  dracula
  kanso
  aamis
  demon
  lumon
  lush
  lush-mono
)

mkdir -p "$DEST"

for theme in "${THEMES[@]}"; do
  helpers::log::info "Installing ${CYAN}$theme${RESET}"
  git clone -q "${URL}-${theme}" "$DEST/$theme"
done

