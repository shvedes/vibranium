#!/bin/bash

helpers::log::info "Applying default theme"

THEME_DIR="$HOME/.config/vibranium/current/theme"
mkdir -p "$THEME_DIR"

mkdir -p "$HOME/.config/btop/themes"
helpers::symlink "$HOME/.config/vibranium/current/theme/btop.theme" \
  "$HOME/.config/btop/themes/vibranium.theme"

gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
gsettings set org.gnome.desktop.interface font-name "Liberation Mono Bold"
gsettings set org.gnome.desktop.interface icon-theme 'Vibranium'

mkdir -p ~/.config/gtk-3.0
printf '* {\n\tborder-radius: 0;\n}\n\n@import "colors.css";' |
  helpers::write_file ~/.config/gtk-3.0/gtk.css

helpers::sed "$HOME/.config/qt5ct/qt5ct.conf" "s/user/$USER/"
helpers::sed "$HOME/.config/qt6ct/qt6ct.conf" "s/user/$USER/"

helpers::symlink "$VIBRANIUM/default/hypr/animations/default.lua" \
  "$HOME/.config/hypr/hyprland.conf.d/animations.lua"

CHROME_FOLDER="/etc/chromium/policies/managed"
CHROME_COLORS="$CHROME_FOLDER/color.json"
BROWSER_COLORS_FILES=("$CHROME_COLORS")

sudo mkdir -p "$CHROME_FOLDER"
sudo chown -R "$USER:$USER" "$CHROME_FOLDER"

if command -v brave >/dev/null; then
  BRAVE_FOLDER="/etc/brave/policies/managed"
  BRAVE_COLORS="$BRAVE_FOLDER/color.json"

  sudo mkdir -p "$BRAVE_FOLDER"
  sudo chown -R "$USER:$USER" "$BRAVE_FOLDER"

  BROWSER_COLORS_FILES+=("$BRAVE_COLORS")
fi

for file in "${BROWSER_COLORS_FILES[@]}"; do
  helpers::backup_path "$file"
  printf '{ "BrowserThemeColor": "#192330" }\n' | sudo tee "$file" >/dev/null
  sudo chown "$USER:$USER" "$file"
done

printf 'theme=Adwaita\nsize=24' > "$HOME/.local/state/vibranium/cursor-theme"

helpers::symlink ~/.config/vibranium/current/theme/neovim.lua ~/.config/nvim/lua/plugins/theme.lua
