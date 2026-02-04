#!/usr/bin/env bash

THEME_PATH="$HOME/.local/share/vibranium/themes/nightfox-nightfox"

# Symlinks
ln -sf "$THEME_PATH" "$HOME/.config/vibranium/theme/current" >/dev/null

# btop
ln -sf "$HOME/.config/vibranium/theme/current/btop.theme" \
	"$HOME/.config/btop/themes/current.theme" >/dev/null

# Discord / Vesktop / Vencord
for dir in Vencord vesktop; do
	target="$HOME/.config/$dir/themes/vibranium.theme.css"
	ln -sf "$HOME/.config/vibranium/theme/current/discord.css" "$target"
	printf '{\n\t"enabledThemes": ["vibranium.theme.css"]\n}' \
		> "$HOME/.config/$dir/settings/settings.json"
done

# Heroic
mkdir -p "$HOME/.config/heroic/store" "$HOME/.config/heroic/themes"
ln -sf "$HOME/.config/vibranium/theme/current/heroic.css" \
	"$HOME/.config/heroic/themes/vibranium.css"
printf '{\n\t"defaultSettings": {"customThemesPath": "%s/.config/heroic/themes"}\n}' "$HOME" \
	> "$HOME/.config/heroic/config.json"
printf '{\n\t"theme": "vibranium.css"\n}' \
	> "$HOME/.config/heroic/store/config.json"

# Misc symlinks
declare -A links=(
	["$HOME/.local/share/vibranium/default/uwsm/env"]="$HOME/.config/uwsm/env"
	["$HOME/.local/share/vibranium/default/imv"]="$HOME/.config/imv/config"
	["$HOME/.config/vibranium/theme/current/qt6ct.conf"]="$HOME/.config/qt6ct/colors/vibranium.conf"
	["$HOME/.config/vibranium/theme/current/qt6ct.conf"]="$HOME/.config/qt5ct/colors/vibranium.conf"
	["$HOME/.local/share/vibranium/default/wlogout/style.css"]="$HOME/.config/wlogout"
	["$HOME/.local/share/vibranium/default/wlogout/layout"]="$HOME/.config/wlogout"
	["$HOME/.config/vibranium/theme/current/spicetify.ini"]="$HOME/.config/spicetify/Themes/text/color.ini"
)

for src in "${!links[@]}"; do
	ln -sf "$src" "${links[$src]}" >/dev/null
done

# GNOME appearance
gsettings set org.gnome.desktop.interface gtk-theme "Nightfox"
gsettings set org.gnome.desktop.interface cursor-theme "macOS"
gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
gsettings set org.gnome.desktop.interface font-name "Cascadia Code"

papirus-folders --theme "Papirus-Dark" --color nordic &>/dev/null

# GTK symlinks
mkdir -p "$HOME/.config/gtk-4.0"
for f in assets gtk-dark.css gtk.css; do
	ln -sf "$HOME/.themes/Nightfox/gtk-4.0/$f" "$HOME/.config/gtk-4.0/"
done

# Icon theme
mkdir -p "$HOME/.local/share/icons"
cp -r ./extras/icon_theme/Vibranium "$HOME/.local/share/icons"

printf "# vim:ft=bash\n# shellcheck disable=all\n# Auto-generated file. Do not edit!\n\n" \
	> "$HOME/.config/vibranium/settings"

cp -r ./config/* "$HOME/.config"
sed -i "s/user/$USER/" "$HOME/.config/qt6ct/qt6ct.conf"

ln -sf "$HOME/.local/share/vibranium/default/hypr/animations/default.conf" \
	"$HOME/.config/hypr/hyprland.conf.d/animations.conf"
