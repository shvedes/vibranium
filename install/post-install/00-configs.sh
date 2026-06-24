#!/usr/bin/env bash

helpers::log::info "Copying configs"

mkdir -p "$HOME/.local/state/vibranium"

# Everything that is pre-configured.
for entry in "$VIBRANIUM"/config/*; do
  [[ -e "$entry" ]] || continue
  vb::copy "$entry" "$HOME/.config/$(basename "$entry")"
done

for entry in "$VIBRANIUM"/config/.*; do
  base="$(basename "$entry")"
  [[ "$base" == "." || "$base" == ".." ]] && continue
  vb::copy "$entry" "$HOME/$base"
done

# Some additional scripts.
# I might move imv auxiliary scripts
# from here eventually. Ideally,
# $VIBRANIUM_PATH is the right place for them.
mkdir -p "$HOME"/.local/bin
for entry in "$VIBRANIUM"/extras/local/bin/*; do
  [[ -e "$entry" ]] || continue
  vb::copy "$entry" "$HOME/.local/bin/$(basename "$entry")"
done

# Custom / Hidden app menu entries
mkdir -p "$HOME"/.local/share/applications

# Previously I used to symlink all of them, but practically speaking it is
# not a good solution. If the user wants to edit one of them or simply
# *unhide* an entry, it will create git conflicts, which **will**
# lead to further confusion and Vibranium update errors.
for entry in "$VIBRANIUM"/applications/*.desktop; do
  [[ -e "$entry" ]] || continue
  vb::copy "$entry" "$HOME/.local/share/applications/$(basename "$entry")"
done

# Don't use brace expansion here for the sake of readability.
for entry in "$VIBRANIUM"/applications/custom/*.desktop; do
  [[ -e "$entry" ]] || continue
  vb::copy "$entry" "$HOME/.local/share/applications/$(basename "$entry")"
done

for entry in "$VIBRANIUM"/applications/hidden/*.desktop; do
  [[ -e "$entry" ]] || continue
  vb::copy "$entry" "$HOME/.local/share/applications/$(basename "$entry")"
done
