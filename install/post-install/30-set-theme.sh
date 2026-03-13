#!/usr/bin/env bash

THEME_PATH="$HOME/.local/share/vibranium/themes/nightfox-nightfox"

cp -r "$HOME/.local/share/vibranium/config/.gtkrc-2.0" "$HOME"

# Symlink the default theme.
# Color for other apps are in there
ln -sf "$THEME_PATH" \
    "$HOME/.config/vibranium/theme/current" >/dev/null

# Symlink the btop theme as well
ln -sf "$HOME/.config/vibranium/theme/current/btop.theme" \
	"$HOME/.config/btop/themes/current.theme" >/dev/null

# Heroic. It is not installed by default, but it will
# automatically apply the active theme on first launch
############################################################

mkdir -p "$HOME"/.config/heroic/{store,themes}

ln -sf "$HOME/.config/vibranium/theme/current/heroic.css" \
	"$HOME/.config/heroic/themes/vibranium.css" >/dev/null

cat > "$HOME/.config/heroic/config.json" <<EOF
{
    "defaultSettings": {
        "customThemesPath": "$HOME/.config/heroic/themes"
    }
}
EOF

cat > "$HOME/.config/heroic/store/config.json" <<EOF
{
    "theme": "vibranium.css"
}
EOF

############################################################

ln -sf "$HOME/.config/vibranium/theme/current/qt6ct.conf" "$HOME"/.config/qt5ct/colors/vibranium.conf
ln -sf "$HOME/.config/vibranium/theme/current/qt6ct.conf" "$HOME"/.config/qt6ct/colors/vibranium.conf

# GNOME appearance
gsettings set org.gnome.desktop.interface gtk-theme "Nightfox"
gsettings set org.gnome.desktop.interface cursor-theme "macOS"
gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
gsettings set org.gnome.desktop.interface font-name "Cascadia Code"

$HOME/.local/bin/papirus-folders --theme "Papirus-Dark" --color nordic &>/dev/null

# GTK symlinks
for f in assets gtk-dark.css gtk.css; do
	ln -sf "$HOME/.local/share/themes/Nightfox/gtk-4.0/$f" "$HOME/.config/gtk-4.0/"
done

# QTCT
sed -i "s/user/$USER/" "$HOME/.config/qt6ct/qt6ct.conf"
sed -i "s/user/$USER/" "$HOME/.config/qt5ct/qt5ct.conf"

ln -sf "$HOME/.local/share/vibranium/default/hypr/animations/default.conf" \
	"$HOME/.config/hypr/hyprland.conf.d/animations.conf"

