#!/usr/bin/env bash

_log_info "Applying default theme"

THEME_PATH="$VIBRANIUM/themes/nightfox-nightfox"

cp -r "$VIBRANIUM/config/.gtkrc-2.0" "$HOME"

# Symlink the default theme.
mkdir -p "$HOME/.config/vibranium/theme"
ln -sf "$THEME_PATH" "$HOME/.config/vibranium/theme/current"

# Symlink the btop theme as well
mkdir -p "$HOME/.config/btop/themes"
ln -sf "$HOME/.config/vibranium/theme/current/btop.theme" \
  "$HOME/.config/btop/themes/current.theme"

# Heroic. It is not installed by default, but it will
# automatically apply the active theme on first launch
############################################################

mkdir -p "$HOME"/.config/heroic/{store,themes}

ln -sf "$HOME/.config/vibranium/theme/current/heroic.css" \
  "$HOME/.config/heroic/themes/vibranium.css"

cat > "$HOME/.config/heroic/config.json" << EOF
{
    "defaultSettings": {
        "customThemesPath": "$HOME/.config/heroic/themes"
    }
}
EOF

cat > "$HOME/.config/heroic/store/config.json" << EOF
{
    "theme": "vibranium.css"
}
EOF

############################################################

# QT colors
mkdir -p "$HOME"/.config/qt{5,6}ct/colors
# Keep line width relatively short
ln -sf "$HOME/.config/vibranium/theme/current/qt5ct.conf" \
  "$HOME"/.config/qt5ct/colors/vibranium.conf
ln -sf "$HOME/.config/vibranium/theme/current/qt6ct.conf" \
  "$HOME"/.config/qt6ct/colors/vibranium.conf
sed -i "s/user/$USER/" "$HOME"/.config/qt*ct/qt*ct.conf

# GNOME appearance
gsettings set org.gnome.desktop.interface gtk-theme "Nightfox"
gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
gsettings set org.gnome.desktop.interface font-name "Cascadia Code"

bash $HOME/.local/bin/papirus-folders --theme "Papirus-Dark" --color nordic &> /dev/null

# GTK symlinks
mkdir -p "$HOME"/.config/gtk-{3,4}.0
for f in assets gtk-dark.css gtk.css; do
  ln -sf "$HOME/.local/share/themes/Nightfox/gtk-4.0/$f" "$HOME"/.config/gtk-4.0/
done

ln -sf "$HOME/.local/share/vibranium/default/hypr/animations/default.conf" \
  "$HOME/.config/hypr/hyprland.conf.d/animations.conf"

# Cursor theme
echo "Adwaita" > "$HOME/.local/state/vibranium/cursor-theme"
echo "24" > "$HOME/.local/state/vibranium/cursor-size"
