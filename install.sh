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
	yay -Suy --needed --noconfirm "$(cat ./pkg_list.txt)"
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
	sudo systemctl disbale display-manager

	sudo systemctl enable "${system_services[@]}"
	systemctl --user enable "${user_services[@]}"
}

install_yay
install_packages
enable_system_services
