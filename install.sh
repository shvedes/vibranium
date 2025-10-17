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
	cp -r ./config/systemd "$HOME/.config/systemd/user"
	cp -r ./config/hypr "$HOME/.config/hypr"
}

generate_defaults() {
	./install/gtk_themes.sh
	./install/papirus_icons.sh

	mkdir -p "$HOME/.config/vibranium/theme"

	printf "# vim:ft=bash\n# Place your environment variables here\n" \
		> "$HOME/.config/vibranium/environment"
	printf "# vim:ft=bash\n# shellcheck disable=all\n# Auto-generated file. Do not edit!\n\n" \
		> "$HOME/.config/vibranium/environment"
	ln -s "$HOME/.local/share/vibranium/defaults/uwsm/env" "$HOME/.config/uwsm/env"
}

install_yay
install_packages

copy_configs
enable_system_services

generate_defaults
./install/local_bin.sh
