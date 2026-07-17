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
  antix
  aamis
  demon
  lumon
  lush
  lush-mono
)

mkdir -p "$DEST"

total=${#THEMES[@]}
current=0

for theme in "${THEMES[@]}"; do
  ((current++))
  git clone -q "${URL}-${theme}" "$DEST/$theme" &
  term::spinner $! "${CYAN}[INFO]${RESET} Installing theme ${GRAY}[${current}/${total}]${RESET}"
done
