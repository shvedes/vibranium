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
		printf "\n%s[VIBRANIUM]%s %sYay installed%s" "${YELLOW}" "${RESET}" "${GREEN}" "${RESET}"
		cd "$cwd"
	fi
}

install_packages() {
	yay -Suy --needed --noconfirm - < ./pkg_list.txt
	clear; printf '\e[2J\e[%d;1H' "$LINES"
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

	sudo systemctl -q enable ly power-profiles-daemon bluetooth
	systemctl -q --user daemon-reload

	for service in "${user_services[@]}"; do
		systemctl -q --user enable "$service"
	done
}

generate_defaults() {
	printf "# vim:ft=bash\n# Place your environment variables here\n" \
		> "$HOME/.config/vibranium/environment"
	printf "# vim:ft=bash\n# shellcheck disable=all\n# Auto-generated file. Do not edit!\n\n" \
		> "$HOME/.config/vibranium/settings"
	ln -s "$HOME/.local/share/vibranium/defaults/uwsm/env" \
		"$HOME/.config/uwsm/env" >/dev/null

	ln -s "$HOME/.local/share/vibranium/defaults/imv" \
		"$HOME/.config/imv/config" >/dev/null

	ln -s "$HOME/.local/share/vibranium/themes/nightfox-nightfox/qt6ct.conf" \
		"$HOME/.config/qt6ct/colors/vibranium.conf" >/dev/null

	ln -s "$HOME/.local/share/vibranium/defaults/wlogout/style.css" \
		"$HOME/.config/wlogout" >/dev/null
	ln -s "$HOME/.local/share/vibranium/defaults/wlogout/layout" \
		"$HOME/.config/wlogout" >/dev/null

	ln -s "$HOME/.config/vibranium/theme/current/spicetify.ini" \
		"$HOME/.config/spicetify/Themes/text/color.ini" >/dev/null
}

apply_default_theme() {
	local theme_path
	theme_path="$HOME/.local/share/vibranium/themes/nightfox-nightfox"

	printf "\n%s[VIBRANIUM]%s Applying the default theme" "${YELLOW}" "${RESET}"
	ln -s "${theme_path}" "$HOME/.config/vibranium/theme/current" >/dev/null
	ln -s "$HOME/.config/vibranium/theme/current/btop.theme" \
		"$HOME/.config/btop/themes/current.theme" >/dev/null

	gsettings set org.gnome.desktop.interface gtk-theme "Nightfox"
	gsettings set org.gnome.desktop.interface cursor-theme "macOS"
	gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
	gsettings set org.gnome.desktop.interface font-name "Cascadia Code"

	ln -s "$HOME/.themes/Nightfox/gtk-4.0/assets" \
		"$HOME/.config/gtk-4.0/"
	ln -s "$HOME/.themes/Nightfox/gtk-4.0/gtk-dark.css" \
		"$HOME/.config/gtk-4.0/"
	ln -s "$HOME/.themes/Nightfox/gtk-4.0/gtk.css" \
		"$HOME/.config/gtk-4.0/"

	mkdir -p "$HOME/.local/share/icons"
	cp -r ./extras/icon_theme/Vibranium "$HOME/.local/share/icons"
}

copy_system_files() {
	sudo cp -r ./extras/udev/rules.d/*  /etc/udev/rules.d
	sudo cp -r ./extras/pacman.d/hooks  /etc/pacman.d
	sudo cp -r ./extras/usr/local/bin/* /usr/local/bin
}

create_directories() {
	mkdir -p \
		"$HOME/.config/spicetify/Themes/text" \
		"$HOME/.config/hypr/hyprland.conf.d" \
		"$HOME/.local/share/applications" \
		"$HOME/.local/state/vibranium/" \
		"$HOME/.config/vibranium/theme" \
		"$HOME/.config/qt6ct/colors" \
		"$HOME/.config/btop/themes/" \
		"$HOME/.config/wlogout" \
		"$HOME/.config/gtk-3.0" \
		"$HOME/.config/gtk-4.0" \
		"$HOME/.config/zathura" \
		"$HOME/.config/swayosd" \
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

printf "\n%s[VIBRANIUM]%s Generating defaults configs" "${YELLOW}" "${RESET}"

create_directories

printf "\n%s[VIBRANIUM]%s Copying configs" "${YELLOW}" "${RESET}"
cp -r ./config/systemd "$HOME/.config/"
cp -r ./config/waybar "$HOME/.config"
cp -r ./config/alacritty "$HOME/.config"
cp -r ./config/rofi "$HOME/.config"
cp -r ./config/hypr/hyprland.conf.d "$HOME/.config/hypr"
cp -r ./config/qt6ct.conf "$HOME/.config/qt6ct"
cp -r ./config/btop.conf "$HOME/.config/btop"

sed -i "s/user/\$USER/" "$HOME/.config/qt6ct/qt6ct.conf"

ln -sf "$(realpath ./applications/custom)" "$HOME"/.local/share/applications/ >/dev/null
for entry in ./applications/hidden/*; do
	ln -sf "$(realpath "$entry")" "$HOME"/.local/share/applications/
done

apply_default_theme
generate_defaults

printf "\n%s[VIBRANIUM]%s Generating defaults" "${YELLOW}" "${RESET}"
for file in ./install/generate_*; do
	bash "$file"
done

printf "\n%s[VIBRANIUM]%s Installing systemd services" "${YELLOW}" "${RESET}"
enable_system_services

printf "\n%s[VIBRANIUM]%s Installation complete%s" "${YELLOW}" "${GREEN}" "${RESET}"
printf "\n%s[VIBRANIUM]%s You can start using Vibranium by typying 'uwsm start hyprland'" "${YELLOW}" "${RESET}"
printf "\n%s[VIBRANIUM]%s Or you can reboot the machine and then select 'Hyprland (uwsm-managed)' in DM\n" "${YELLOW}" "${RESET}"
