#!/usr/bin/env bash

set -euo pipefail

export SUDO_PROMPT
SUDO_PROMPT="$(printf '\n\033[1;31m[sudo]\033[0m Password for %s: ' "$USER")"

RED=$'\e[0;31m'
YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
GRAY=$'\e[90m'
RESET=$'\e[0m'

if [[ "$(id -u)" == 0 ]]; then
	echo "${RED}[ERROR]${RESET} Do not run this as root!"
	exit 1
fi

sudo -v

cleanup() {
	touch "$HOME/.local/state/vibranium/first-boot"
	yay -Ycc --noconfirm &>/dev/null
}

edit_system_configs() {
	local pacman_conf makepkg_conf system_auth_conf
	local sudoers_conf faillock_conf 

	pacman_conf="/etc/pacman.conf"
	makepkg_conf="/etc/makepkg.conf"
	sudoers_conf="/etc/sudoers"
	faillock_conf="/etc/security/faillock.conf"
	system_auth_conf="/etc/pam.d/system-auth"

	printf "\n%s[VIBRANIUM]%s Editing /etc/pacman.conf" "${YELLOW}" "${RESET}"
	if grep -q '^\[multilib\]' "$pacman_conf" && grep -q '^Color' "$pacman_conf" && grep -q '^VerbosePkgLists' "$pacman_conf" && grep -q '^ParallelDownloads = 10' "$pacman_conf"; then
		printf "\n%s[VIBRANIUM]%s /etc/pacman.conf already configured, skipping" "${YELLOW}" "${RESET}"
	else
		sudo sed -i -e '/\[multilib\]/,/^$/s/^#//' \
			-e '/^\s*#Color/s/^#//' \
			-e '/^\s*#VerbosePkgLists/s/^#//' \
			-e '/^\s*#ParallelDownloads/s/^#//' \
			-e 's/^\s*ParallelDownloads\s*=.*/ParallelDownloads = 10/' "$pacman_conf"
	fi

	printf "\n%s[VIBRANIUM]%s Editing /etc/makepkg.conf" "${YELLOW}" "${RESET}"
	if grep -q '-march=native' "$makepkg_conf" && ! grep -qE "^OPTIONS([^#]*[^!]debug)" "$makepkg_conf"; then
		printf "\n%s[VIBRANIUM]%s /etc/makepkg.conf already configured, skipping" "${YELLOW}" "${RESET}"
	else
		sudo sed -i -e 's/-march=x86-64/-march=native/' \
			-e '/^OPTIONS=/ s/\bdebug\b/!debug/' "$makepkg_conf"
	fi

	sudo pacman -Suy --noconfirm &>/dev/null

	printf "\n%s[VIBRANIUM]%s Editing /etc/sudoers" "${YELLOW}" "${RESET}"
	if sudo grep -qxF '## VIBRANIUM: Enable interactive prompt' "$sudoers_conf"; then
		printf "\n%s[VIBRANIUM]%s /etc/sudoers already configured, skipping" "${YELLOW}" "${RESET}"
	else
		echo -e '\n## VIBRANIUM: Enable interactive prompt\nDefaults env_reset,pwfeedback' \
			| sudo tee -a "$sudoers_conf" &>/dev/null
	fi

	printf "\n%s[VIBRANIUM]%s Editing /etc/security/faillock.conf" "${YELLOW}" "${RESET}"
	if grep -qxF 'nodelay' "$faillock_conf"; then
		printf "\n%s[VIBRANIUM]%s /etc/security/faillock.conf already configured, skipping" "${YELLOW}" "${RESET}"
	else
		echo -e 'deny = 5\nnodelay' | sudo tee -a "$faillock_conf" &>/dev/null
	fi

	printf "\n%s[VIBRANIUM]%s Editing /etc/pam.d/system-auth" "${YELLOW}" "${RESET}"
	if sudo grep -q '^auth.*pam_unix\.so.*try_first_pass nullok nodelay' "$system_auth_conf"; then
		printf "\n%s[VIBRANIUM]%s /etc/pam.d/system-auth already configured, skipping" "${YELLOW}" "${RESET}"
	else
		sudo sed -i '/^auth.*pam_unix\.so.*try_first_pass nullok/ s/\(try_first_pass nullok\)/\1 nodelay/' "$system_auth_conf"
	fi
}

install_packages() {
	clear; printf '\e[2J\e[%d;1H' "$LINES"
    printf '\e[?25l'  # hide cursor

    if ! command -v yay >/dev/null; then
        printf "%s[VIBRANIUM]%s Installing %syay%s" "${YELLOW}" "${RESET}" "${GRAY}" "${RESET}"
        if ! command -v git >/dev/null; then
            sudo pacman -S git --noconfirm
        fi

        local cwd; cwd="$(pwd)"
        cd "$(mktemp -d)" || exit
        git clone -q https://aur.archlinux.org/yay
        cd yay || exit
        makepkg -sirc --noconfirm &> /dev/null
        printf "\n%s[VIBRANIUM]%s %sYay installed%s" "${YELLOW}" "${RESET}" "${GREEN}" "${RESET}"
        cd "$cwd" || exit
    fi

	clear; printf '\e[2J\e[%d;1H' "$LINES"
    # Install packages from list

	local packages
	mapfile -t packages < ./pkg_list.txt

	case "$(lspci | grep VGA)" in
		*Radeon*|*AMD*|*ATI*)
			packages+=(
				"mesa"
				"lib32-mesa"
				"mesa-vdpau"
				"lib32-mesa-vdpau"
				"vulkan-radeon"
				"lib32-vulkan-radeon"
				"libvdpau-va-gl"
			)
			;;
		*Intel*|*UHD*|*Iris*|*Arc*)
			packages+=(
				"mesa"
				"lib32-mesa"
				"libvpl"
				"mesa-vdpau"
				"lib32-mesa-vdpau"
				"vulkan-intel"
				"lib32-vulkan-intel"
				"libvdpau-va-gl"
				"vpl-gpu-rt"
			)
			;;
	esac

	# Сортировка массива, безопасная для элементов с пробелами
	mapfile -t packages < <(printf "%s\n" "${packages[@]}" | sort -u)

    # printf '\e[?25l'  # hide cursor

    for pkg in "${packages[@]}"; do
        [[ -z "${pkg//[[:space:]]/}" ]] && continue
        [[ "${pkg:0:1}" == "#" ]] && continue

        printf "\r\033[K%s[VIBRANIUM]%s Installing %s%s%s" "$YELLOW" "$RESET" "$GRAY" "$pkg" "$RESET"
        yay -Suy --noconfirm --needed "$pkg" >/dev/null 2>&1
    done

    printf "\r\033[K%s[VIBRANIUM]%s All packages installed%s\n" "$YELLOW" "${GREEN}" "$RESET"
    printf '\e[?25h'  # show cursor
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
	printf "\n%s[VIBRANIUM]%s Generating defaults configs" "${YELLOW}" "${RESET}"

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

	# chromium --no-startup-window --set-theme-color="25, 35, 48" &>/dev/null

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
	printf "%s[VIBRANIUM]%s Copying system files" "${YELLOW}" "${RESET}"
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

# Clear VT
printf '\e[2J\e[%d;1H' "$LINES"

copy_system_files
edit_system_configs
install_packages
create_directories

bash ./install/install_gtk_themes.sh
bash ./install/install_papirus_icons.sh
bash ./install/install_local_bin.sh

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

for entry in ./applications/*.desktop ./applications/hidden/*; do
    ln -sf "$(realpath "$entry")" "$HOME/.local/share/applications/" >/dev/null
done

apply_default_theme
generate_defaults

printf "\n%s[VIBRANIUM]%s Generating defaults" "${YELLOW}" "${RESET}"
for file in ./install/generate_*; do
	bash "$file"
done

printf "\n%s[VIBRANIUM]%s Installing systemd services" "${YELLOW}" "${RESET}"
enable_system_services
cleanup

printf "\n%s[VIBRANIUM]%s Installation complete%s" "${YELLOW}" "${GREEN}" "${RESET}"
printf "\n%s[VIBRANIUM]%s You can start using Vibranium by typying 'uwsm start hyprland'" "${YELLOW}" "${RESET}"
printf "\n%s[VIBRANIUM]%s Or you can reboot the machine and then select 'Hyprland (uwsm-managed)' in DM\n" "${YELLOW}" "${RESET}"
