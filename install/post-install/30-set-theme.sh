#!/bin/bash

helpers::log::info "Applying default theme"

THEME_DIR="$HOME/.local/state/vibranium/theme"
mkdir -p "$THEME_DIR"

mkdir -p "$HOME/.config/btop/themes"
helpers::symlink "$HOME/.local/state/vibranium/theme/btop.theme" \
	"$HOME/.config/btop/themes/vibranium.theme"

gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
gsettings set org.gnome.desktop.interface font-name "JetBrains Mono"

mkdir -p ~/.config/gtk-3.0
printf '* {\n\tborder-radius: 0;\n}\n\n@import "colors.css";' |
	helpers::write_file ~/.config/gtk-3.0/gtk.css

helpers::sed "$HOME/.config/qt5ct/qt5ct.conf" "s/user/$USER/"
helpers::sed "$HOME/.config/qt6ct/qt6ct.conf" "s/user/$USER/"

helpers::symlink "$VIBRANIUM/default/hypr/animations/fast.lua" \
	"$HOME/.config/hypr/hyprland.conf.d/animations.lua"

CHROME_FOLDER="/etc/chromium/policies/managed"
CHROME_COLORS="$CHROME_FOLDER/color.json"
BROWSER_COLORS_FILES=("$CHROME_COLORS")

sudo mkdir -p "$CHROME_FOLDER"
sudo chown -R "$USER:$USER" "$CHROME_FOLDER"

if command -v brave > /dev/null; then
	BRAVE_FOLDER="/etc/brave/policies/managed"
	BRAVE_COLORS="$BRAVE_FOLDER/color.json"

	sudo mkdir -p "$BRAVE_FOLDER"
	sudo chown -R "$USER:$USER" "$BRAVE_FOLDER"

	BROWSER_COLORS_FILES+=("$BRAVE_COLORS")
fi

for file in "${BROWSER_COLORS_FILES[@]}"; do
	helpers::backup_path "$file"
	printf '{ "BrowserThemeColor": "#141414" }\n' | sudo tee "$file"
	sudo chown "$USER:$USER" "$file"
done

mkdir -p "$HOME/.local/state/vibranium"
printf '{"theme": "Adwaita", "size": 24}\n' > "$HOME/.local/state/vibranium/cursor-theme.json"

helpers::symlink ~/.local/state/vibranium/theme/neovim.lua ~/.config/nvim/lua/plugins/theme.lua
