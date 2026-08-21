#!/bin/bash

GREEN=$'\e[0;32m'
RED=$'\e[0;31m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

# Move generated theme data out of the config dir into the XDG state dir.
#
#   old: ~/.config/vibranium/current/{theme,next-theme,theme.name,background}
#   new: $XDG_STATE_HOME/vibranium/{theme,theme.name,background}
#
# next-theme is transient staging data written by vb-theme-set into
# $VIBRANIUM_CACHE now; it is dropped, not migrated.
#
# Every step is guarded, so the script can safely run twice and tolerates
# partially migrated installs.

old_dir="$XDG_CONFIG_HOME/vibranium/current"
new_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vibranium"

if [[ -d $old_dir ]]; then
  mkdir -p "$new_dir"

  # Migrate theme/ and theme.name one by one. If the state copy already
  # exists, updated code has written it after this migration shipped;
  # the config-side copy is stale in that case and gets discarded.
  for item in theme theme.name; do
    if [[ ! -e "$old_dir/$item" ]]; then
      continue
    fi

    if [[ -e "$new_dir/$item" ]]; then
      rm -rf "${old_dir:?}/${item}"
      echo "${GREEN}[MIGRATION|$SELF]${RESET} Discarded stale ${item} (state copy already active)"
    else
      mv "$old_dir/$item" "$new_dir/$item"
      echo "${GREEN}[MIGRATION|$SELF]${RESET} Moved ${item} -> $new_dir/${item}"
    fi
  done

  # Staging directory is transient; the new location lives in the cache.
  rm -rf "$old_dir/next-theme"

  # Recreate the background symlink against the new theme dir. readlink
  # works even though moving theme/ may have orphaned the old target.
  # The target is stored relative to the state dir, matching what
  # vb-core-wallpaper writes.
  if [[ -L "$old_dir/background" ]]; then
    if [[ ! -e "$new_dir/background" ]]; then
      base="$(readlink "$old_dir/background")"
      base="${base##*/}"
      ln -sfn "theme/backgrounds/$base" "$new_dir/background"
      echo "${GREEN}[MIGRATION|$SELF]${RESET} Recreated background -> theme/backgrounds/$base"
    fi
    rm -f "$old_dir/background"
  fi

  # Drop the old dir when empty; leftover user files keep it alive on purpose.
  if rmdir "$old_dir" 2> /dev/null; then
    echo "${GREEN}[MIGRATION|$SELF]${RESET} Removed $old_dir"
  elif [[ -d $old_dir ]]; then
    echo "${RED}[MIGRATION|$SELF]${RESET} Not empty, left in place: $old_dir"
  fi
fi

# rewrite <file> <sed-expr>
# Applies one substitution; files without old fragments stay untouched.
rewrite() {
  local file="$1" expr="$2"

  if [[ -f $file ]] && grep -qE '(\.\./|\.config/)vibranium/current/' "$file"; then
    sed -i -E "$expr" "$file"
    echo "${GREEN}[MIGRATION|$SELF]${RESET} Updated $file"
  fi
}

# Two path shapes appear in app configs:
#   relative imports from ~/.config/<app>/:  ../vibranium/current/
#   tilde or absolute paths:                 .config/vibranium/current/
# The second form keeps its prefix, which is what makes it correct for
# apps without variable expansion: '~/' and '/home/<user>/' survive as-is,
# only the '.config/vibranium/current' part is swapped for the state path.
fix_config() {
  local file="$1"

  rewrite "$file" \
    's@\.\./vibranium/current/@../../.local/state/vibranium/@g'
  rewrite "$file" \
    's@\.config/vibranium/current/@.local/state/vibranium/@g'
}

for file in \
  "$HOME/.config/alacritty/alacritty.toml" \
  "$HOME/.config/hypr/hyprlock.conf" \
  "$HOME/.config/waybar/style.css" \
  "$HOME/.config/zathura/zathurarc" \
  "$HOME/.config/foot/foot.ini"; do
  fix_config "$file"
done

# rofi resolves @import through its own search path, so the old relative
# form worked only by accident of that resolution order. Point every theme
# file at the new location directly - rofi expands '~'.
for file in "$HOME/.config/rofi/themes/"*.rasi; do
  rewrite "$file" \
    's@\.\./vibranium/current/@~/.local/state/vibranium/@g'
  rewrite "$file" \
    's@\.config/vibranium/current/@.local/state/vibranium/@g'
done

# qt5ct/qt6ct expand nothing: the value must stay absolute. The replacement
# preserves whichever home prefix (/home/user placeholder or real path)
# the file already carries.
for file in "$HOME/.config/qt5ct/qt5ct.conf" "$HOME/.config/qt6ct/qt6ct.conf"; do
  rewrite "$file" \
    's@\.config/vibranium/current/@.local/state/vibranium/@g'
done

# relink <symlink> <new-target>
# Retarget symlinks owned by Vibranium that still point into the old tree.
relink() {
  local link="$1" target="$2" cur

  if [[ -L $link ]]; then
    cur="$(readlink "$link")"
    if [[ $cur == *vibranium/current/* ]]; then
      ln -sfn "$target" "$link"
      echo "${GREEN}[MIGRATION|$SELF]${RESET} Retargeted $link"
    fi
  fi
}

relink "$HOME/.config/yazi/theme.toml" "$new_dir/theme/yazi.toml"
relink "$HOME/.config/hypr/hyprtoolkit.conf" "$new_dir/theme/hyprtoolkit.conf"
relink "$HOME/.config/btop/themes/vibranium.theme" "$new_dir/theme/btop.theme"

# Only a symlink is retargeted here; nvim configs that outgrew it are
# regular files managed by nvim itself and are never touched.
relink "$HOME/.config/nvim/lua/plugins/theme.lua" "$new_dir/theme/neovim.lua"

for editor in "$HOME"/.vscode*/extensions/vibranium.theme \
  "$HOME"/.cursor/extensions/vibranium.theme; do
  relink "$editor/themes/vibranium.json" "$new_dir/theme/vscode.json"
done

# Normalize a background link that already lives in the state dir but
# still stores an absolute self-referencing target.
if [[ -L "$new_dir/background" ]]; then
  cur="$(readlink "$new_dir/background")"
  if [[ $cur == "$new_dir/theme/backgrounds/"* ]]; then
    ln -sfn "theme/backgrounds/${cur##*/}" "$new_dir/background"
    echo "${GREEN}[MIGRATION|$SELF]${RESET} Normalized background -> theme/backgrounds/${cur##*/}"
  fi
fi

# User-local nvim glue that watches the theme dir for swaps. Only the exact
# path fragment is rewritten, so hand-written code around it stays intact.
rewrite "$HOME/.config/nvim/lua/utils/theme.lua" \
  's@~/\.config/vibranium/current/theme@~/.local/state/vibranium/theme@g'
rewrite "$HOME/.config/nvim/lua/utils/theme.lua" \
  's@/\.config/vibranium/current/theme@/.local/state/vibranium/theme@g'

exit 0
