#!/bin/bash

readonly _THEME_SRC="$VIBRANIUM/extras/vscode/vibranium.theme"
readonly _THEME_JSON="$HOME/.config/vibranium/current/theme/vscode.json"

for editor_dir in \
  "$HOME/.vscode" \
  "$HOME/.vscode-insiders" \
  "$HOME/.vscode-oss" \
  "$HOME/.vscode-oss-insiders" \
  "$HOME/.cursor"
do
  mkdir -p "$editor_dir/extensions"

  helpers::copy "$_THEME_SRC" "$editor_dir/extensions/$(basename "$_THEME_SRC")"

  helpers::symlink \
    "$_THEME_JSON" \
    "$editor_dir/extensions/vibranium.theme/themes/vibranium.json"
done
