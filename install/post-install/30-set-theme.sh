#!/usr/bin/env bash

_log_info "Applying default theme"

THEME_PATH="$HOME/.local/share/vibranium/themes/nightfox-nightfox"

cp -r "$VIBRANIUM/config/.gtkrc-2.0" "$HOME"

# Symlink the default theme.
ln -sf "$THEME_PATH" "$VIBRANIUM/theme/current"

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
qt_target="$HOME"/.config/qt{5,6}ct/colors/vibranium.conf
ln -sf "$HOME/.config/vibranium/theme/current/qt6ct.conf" $qt_target
sed -i "s/user/$USER/" "$HOME"/.config/qt{5,6}ct/qt{5,6}ct.conf

# GNOME appearance
gsettings set org.gnome.desktop.interface gtk-theme "Nightfox"
gsettings set org.gnome.desktop.interface cursor-theme "macOS"
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

