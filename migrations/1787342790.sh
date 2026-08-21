#!/bin/bash

GREEN=$'\e[0;32m'
RED=$'\e[0;31m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

themes_dir="$XDG_CONFIG_HOME/vibranium/themes"

# Theme data lives in the config dir before the state-dir migration runs,
# and in the state dir after it. Old path wins while both exist.
name_file="$XDG_CONFIG_HOME/vibranium/current/theme.name"
if ! [[ -f $name_file ]]; then
  name_file="$VIBRANIUM_STATE/theme.name"
fi

current=""
if [[ -f $name_file ]]; then
  current="$(< "$name_file")"
fi

[[ -d "$themes_dir" ]] || exit 0

shopt -s nullglob
repos=("$themes_dir"/*/.git)
shopt -u nullglob

if ((${#repos[@]} == 0)); then
  exit 0
fi

for gitdir in "${repos[@]}"; do
  repo="${gitdir%/.git}"
  name="${repo##*/}"

  if git -C "$repo" pull --ff-only --quiet 2> /dev/null; then
    echo "${GREEN}[MIGRATION|$SELF]${RESET} Updated theme ${name}"
  else
    echo "${RED}[MIGRATION|$SELF]${RESET} Could not update ${name}, please update it manually"
  fi
done

# Re-apply the active theme so generated configs pick up the updated palette.
if [[ -n "$current" ]]; then
  vb-theme-set --force "$current"
fi
