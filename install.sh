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
	local user_services

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

	sudo systemctl enable ly power-profiles-daemon bluetooth
	systemctl --user daemon-reload

	for service in "${user_services[@]}"; do
		systemctl --user enable "$service"
	done
}

generate_defaults() {
	printf "# vim:ft=bash\n# Place your environment variables here\n" \
		> "$HOME/.config/vibranium/environment"
	printf "# vim:ft=bash\n# shellcheck disable=all\n# Auto-generated file. Do not edit!\n\n" \
		> "$HOME/.config/vibranium/settings"
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

copy_system_files() {
	sudo cp -rv ./extras/udev/rules.d/*  /etc/udev/rules.d
	sudo cp -rv ./extras/pacman.d/hooks  /etc/pacman.d
	sudo cp -rv ./extras/usr/local/bin/* /usr/local/bin
}

create_directories() {
	mkdir -pv \
		"$HOME/.config/spicetify/Themes/text" \
		"$HOME/.config/hypr/hyprland.conf.d" \
		"$HOME/.local/state/vibranium/" \
		"$HOME/.config/vibranium/theme" \
		"$HOME/.config/qt6ct/colors" \
		"$HOME/.config/dunst" \
		"$HOME/.config/uwsm" \
		"$HOME/.config/imv"
}

post_install() {
	echo "suspended" > \
		"$HOME/.local/state/vibranium/night-light"
}

install_yay
install_packages
copy_system_files

bash ./install/install_gtk_themes.sh
bash ./install/install_papirus_icons.sh
bash ./install/install_local_bin.sh

echo -e "${YELLOW}[VIBRANIUM]${RESET} Generating defaults configs"

create_directories

echo "${YELLOW}[VIBRANIUM]${RESET} Copying defaults configs"
cp -rf ./config/systemd "$HOME/.config/"
cp -rf ./config/waybar "$HOME/.config"
cp -rf ./config/alacritty "$HOME/.config"
cp -rf ./config/rofi "$HOME/.config"
cp -rf ./config/hypr/hyprland.conf.d "$HOME/.config/hypr"

download_spicetify_theme
generate_defaults

for file in ./install/generate_*; do
	bash "$file"
done

apply_default_theme
mkdir -p "$HOME/.local/share/icons"
cp -rv ./extras/icon_theme/Vibranium "$HOME/.local/share/icons"

enable_system_services
