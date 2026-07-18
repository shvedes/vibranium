#!/bin/bash

helpers::log::info "Copying configs"

mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.local/state/vibranium"
mkdir -p "$HOME/.local/share/applications"

for entry in "$VIBRANIUM"/config/*; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.config/${entry##*/}"
done

for entry in "$VIBRANIUM"/config/.*; do
  base="${entry##*/}"
  [[ "$base" == "." || "$base" == ".." ]] && continue
  helpers::copy "$entry" "$HOME/$base"
done

for entry in "$VIBRANIUM"/extras/local/bin/*; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.local/bin/${entry##*/}"
done

for entry in "$VIBRANIUM"/applications/*.desktop; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.local/share/applications/${entry##*/}"
done

for entry in "$VIBRANIUM"/applications/custom/*.desktop; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.local/share/applications/${entry##*/}"
done

for entry in "$VIBRANIUM"/applications/hidden/*.desktop; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.local/share/applications/${entry##*/}"
done
