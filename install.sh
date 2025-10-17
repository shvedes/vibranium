#!/usr/bin/env bash

set -euo pipefail

RED=$'\e[0;31m'
YELLOW=$'\e[0;33m'
BLUE=$'\e[0;34m'
PURPLE=$'\e[0;35m'
GREEN=$'\e[0;32m'
CYAN=$'\e[0;36m'
GRAY=$'\e[90m'
RESET=$'\e[0m'

if [[ "$(id -u)" == 0 ]]; then
	echo "${RED}[ERROR]${RESET} Do not run this as root!"
	exit 1
fi

install_yay() {
	if ! command -v yay >/dev/null; then
		echo -e "${YELLOW}[VIBRANIUM]${RESET} Installing yay"
		if ! command -v git >/dev/null; then
			sudo pacman -S git --noconfirm
		fi
		
		local cwd; cwd="$(pwd)"
		cd "$(mktemp -d)"
		git clone https://aur.archlinux.org/yay; cd yay
		makepkg -sirc --noconfirm
		echo -e "${YELLOW}[VIBRANIUM]${RESET} ${GREEN}Yay installed${RESET}"
		cd "$cwd"
	fi
}

install_packages() {
	yay -Suy --needed --noconfirm - < ./pkg_list.txt
}

enable_system_services() {
	local system_services
	local user_services

	system_services=(
		"power-profiles-daemon"
		"ly"
	)
	user_services=(
		"waybar"
		"swayosd"
		"cliphist"
		"hypridle"
		"hyprpaper"
		"hyprsunset"
		"gnome-polkit"
	)

	echo -e "${YELLOW}[VIBRANIUM]${RESET} Enabling systemd services"
# 	sudo systemctl disable display-manager

	sudo systemctl enable "${system_services[@]}"
	systemctl --user enable "${user_services[@]}"
}

copy_configs() {
	echo "${YELLOW}[VIBRANIUM]${RESET} Copying defaults configs"
	cp -rf ./config/systemd "$HOME/.config/systemd/user"
	cp -rf ./config/waybar "$HOME/.config"
	cp -rf ./config/alacritty "$HOME/.config"
}

generate_defaults() {
	mkdir -p \
		"$HOME/.config/vibranium/theme" \
		"$HOME/.config/qt6ct/colors" \
		"$HOME/.config/dunst" \
		"$HOME/.config/imv"

	printf "# vim:ft=bash\n# Place your environment variables here\n" \
		> "$HOME/.config/vibranium/environment"
	printf "# vim:ft=bash\n# shellcheck disable=all\n# Auto-generated file. Do not edit!\n\n" \
		> "$HOME/.config/vibranium/environment"
	ln -s "$HOME/.local/share/vibranium/defaults/uwsm/env" "$HOME/.config/uwsm/env"

	ln -s "$HOME/.local/share/vibranium/defaults/imv" \
		"$HOME/.config/imv/config"

	ln -s "$HOME/.local/share/vibranium/themes/nightfox-nightfox/qt6ct.conf" \
		"$HOME/.config/qt6ct/colors/vibranium.conf"
}

apply_default_theme() {
	local theme_path
	theme_path="$HOME/.local/share/vibranium/themes/nightfox-nightfox"

	echo -e "${YELLOW}[VIBRANIUM]${RESET} Applying the default theme"
	ln -s "${theme_path}" "$HOME/.config/vibranium/theme/current"
}

download_spicetify_theme() {
	curl -s "https://raw.githubusercontent.com/spicetify/spicetify-themes/refs/heads/master/text/user.css" \
		-o "${XDG_CONFIG_HOME:-$HOME/.config}/spicetify/Themes/text/user.css"
}

install_yay
install_packages

./install/install_gtk_themes.sh
./install/install_papirus_icons.sh

echo -e "${YELLOW}[VIBRANIUM]${RESET} Generating defaults configs"

copy_configs
generate_defaults

for file in ./install/generate_*.sh; do
	bash "$file"
done

apply_default_theme
enable_system_services

# ./install/local_bin.sh
