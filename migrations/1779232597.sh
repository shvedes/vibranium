#!/usr/bin/bash

SELF="${0##*/}"
GREEN=$'\e[0;32m'
RESET=$'\e[0m'

THEMES_DIR="$XDG_CONFIG_HOME/vibranium/themes"
THEMES_BAK="$XDG_CONFIG_HOME/vibranium/themes.bak"

echo "${GREEN}[MIGRATION|${SELF}]${RESET} To maintain small repo size. All the wallpapers for each theme were moved to a separate repo."
echo "${GREEN}[MIGRATION|${SELF}]${RESET} Now we need to download them \"from scratch\""

if [[ -d "$THEMES_DIR" ]]; then
  mv "$THEMES_DIR" "$THEMES_BAK"
fi

git clone "https://github.com/shvedes/vibrnaium-wallpapers" "$THEMES_DIR"
rm -rf "$THEMES_DIR/.git" "$THEMES_DIR/.github"

if [[ -d "$THEMES_BAK" ]]; then
  while IFS= read -r theme_dir; do
    theme_name=$(basename "$theme_dir")

    if [[ ! -d "$THEMES_DIR/$theme_name" ]]; then
      # Theme doesn't exist in the fresh clone at all -- full copy.
      echo "${GREEN}[MIGRATION|${SELF}]${RESET} Preserving user theme: $theme_name"
      cp -r "$theme_dir" "$THEMES_DIR/$theme_name"
      continue
    fi

    # Theme exists in both -- check for user-added wallpapers inside
    # backgrounds/ that are absent from the freshly cloned version.
    bak_bg="$theme_dir/backgrounds"
    new_bg="$THEMES_DIR/$theme_name/backgrounds"

    [[ -d "$bak_bg" ]] || continue

    while IFS= read -r img_file; do
      img_name=$(basename "$img_file")

      if [[ ! -f "$new_bg/$img_name" ]]; then
        echo "${GREEN}[MIGRATION|${SELF}]${RESET} $theme_name: preserving your wallpaper - $img_name"
        mkdir -p "$new_bg"
        cp "$img_file" "$new_bg/$img_name"
      fi
    done < <(find "$bak_bg" -maxdepth 1 -type f | sort)
  done < <(find "$THEMES_BAK" -mindepth 1 -maxdepth 1 -type d | sort)

  rm -rf "$THEMES_BAK"
fi
