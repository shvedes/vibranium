#!/usr/bin/env bash

_log_info "Applying default theme"

THEME_DIR="$HOME/.config/vibranium/current/theme"
mkdir -p "$THEME_DIR"

# Symlink the btop theme
mkdir -p "$HOME/.config/btop/themes"
ln -sf "$HOME/.config/vibranium/current/theme/btop.theme" \
  "$HOME/.config/btop/themes/vibranium.theme"

# GNOME / GTK
gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
gsettings set org.gnome.desktop.interface font-name "Cascadia Code"
gsettings set org.gnome.desktop.interface icon-theme 'Vibranium'

# QTCT
sed -i "s/user/$USER/" "$HOME/.config/qt5ct/qt5ct.conf"
sed -i "s/user/$USER/" "$HOME/.config/qt6ct/qt6ct.conf"

# Default animations preset
ln -sf "$VIBRANIUM/default/hypr/animations/default.conf" \
  "$HOME/.config/hypr/hyprland.conf.d/animations.conf"

# Browser colors
CHROME_FOLDER="/etc/chromium/policies/managed"
CHROME_COLORS="$CHROME_FOLDER/color.json"
BROWSER_COLORS_FILES=("$CHROME_COLORS")

sudo mkdir -p "$CHROME_FOLDER"
sudo chown -R "$USER:$USER" "$CHROME_FOLDER"

# In case if user chose brave is browser of choise.
if command -v brave >/dev/null; then
  BRAVE_FOLDER="/etc/brave/policies/managed"
  BRAVE_COLORS="$BRAVE_FOLDER/color.json"

  sudo mkdir -p "$BRAVE_FOLDER"
  sudo chown -R "$USER:$USER" "$BRAVE_FOLDER"

  BROWSER_COLORS_FILES+=("$BRAVE_COLORS")
fi

for file in "${BROWSER_COLORS_FILES[@]}"; do
  printf '{ "BrowserThemeColor": "#192330" }\n' >"$file"
done

# Cursor theme
echo "Adwaita" >"$HOME/.local/state/vibranium/cursor-theme"
echo "24" >"$HOME/.local/state/vibranium/cursor-size"

ln -s ~/.config/vibranium/current/theme/neovim.lua ~/.config/nvim/lua/plugins/theme.lua
