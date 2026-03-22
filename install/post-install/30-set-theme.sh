#!/usr/bin/env bash

_log_info "Applying default theme"

DEFAULT_THEME="$VIBRANIUM/themes/nightfox-nightfox"
THEME_PATH="$HOME/.config/vibranium/current/theme"

# Symlink the default theme.
mkdir -p "$THEME_PATH"
cp -r "$DEFAULT_THEME"/* "$THEME_PATH"
ln -s "$THEME_PATH/backgrounds/01-nightfox-bg.jpg" \
  "$HOME/.config/vibranium/current/background"
echo "nightfox-nightfox" >"$HOME/.config/vibranium/current/theme.name"

# Symlink the btop theme as well
mkdir -p "$HOME/.config/btop/themes"
ln -sf "$HOME/.config/vibranium/current/theme/btop.theme" \
  "$HOME/.config/btop/themes/vibranium.theme"

# GNOME / GTK
gsettings set org.gnome.desktop.interface gtk-theme "adw-gtk3"
gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
gsettings set org.gnome.desktop.interface font-name "Cascadia Code"

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
