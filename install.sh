#!/usr/bin/env bash

set -euo pipefail

export SUDO_PROMPT
SUDO_PROMPT="$(printf '\n\033[1;31m[sudo]\033[0m Password for %s: ' "$USER")"

THEME_PATH="$HOME/.local/share/vibranium/themes/nightfox-nightfox"

PACMAN_CONF="/etc/pacman.conf"
MAKEPKG_CONF="/etc/makepkg.conf"
SUDOERS_CONF="/etc/sudoers"
FAILLOCK_CONF="/etc/security/faillock.conf"
SYSTEM_AUTH_CONF="/etc/pam.d/system-auth"

RED=$'\e[0;31m'
YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
GRAY=$'\e[90m'
RESET=$'\e[0m'

if [[ "$(id -u)" == 0 ]]; then
	echo "${RED}[ERROR]${RESET} Do not run this as root!"
	exit 1
fi

if ! command -v yay >/dev/null; then
	printf "%s[VIBRANIUM]%s Installing %syay%s" "${YELLOW}" "${RESET}" "${GRAY}" "${RESET}"
	if ! command -v git >/dev/null; then
		sudo pacman -S git --noconfirm
	fi

	CWD="$(pwd)"
	cd "$(mktemp -d)" || exit
	git clone -q https://aur.archlinux.org/yay
	cd yay || exit
	makepkg -sirc --noconfirm &> /dev/null
	cd "$CWD" || exit
fi

# Hide cursor
printf '\e[?25l'

cleanup() {
	touch "$HOME/.local/state/vibranium/first-boot"
	yay -Ycc --noconfirm &>/dev/null
}

install_packages() {
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

	mapfile -t packages < <(printf "%s\n" "${packages[@]}" | sort -u)

    for pkg in "${packages[@]}"; do
        [[ -z "${pkg//[[:space:]]/}" ]] && continue
        [[ "${pkg:0:1}" == "#" ]] && continue

        printf "\r\033[K%s[VIBRANIUM]%s Installing %s%s%s" "$YELLOW" "$RESET" "$GRAY" "$pkg" "$RESET"
        yay -Suy --noconfirm --needed "$pkg" >/dev/null 2>&1
    done

    printf "\r\033[K%s[VIBRANIUM]%s All packages installed%s\n" "$YELLOW" "${GREEN}" "$RESET"
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

sudo -v; clear
# Move VT to the bottom
printf '\e[2J\e[%d;1H' "${LINES:-$(tput lines)}"
cat ./logo.txt

printf "%s[VIBRANIUM]%s Setting up system files\n" "${YELLOW}" "${RESET}"
sudo cp -r ./extras/udev/rules.d/*  /etc/udev/rules.d
sudo cp -r ./extras/pacman.d/hooks  /etc/pacman.d
sudo cp -r ./extras/usr/local/bin/* /usr/local/bin

if ! (grep -q '^\[multilib\]' "$PACMAN_CONF" && \
      grep -q '^Color' "$PACMAN_CONF" && \
      grep -q '^VerbosePkgLists' "$PACMAN_CONF" && \
      grep -q '^ParallelDownloads = 10' "$PACMAN_CONF"); then
	sudo sed -i -e '/\[multilib\]/,/^$/s/^#//' \
		-e '/^\s*#Color/s/^#//' \
		-e '/^\s*#VerbosePkgLists/s/^#//' \
		-e '/^\s*#ParallelDownloads/s/^#//' \
		-e 's/^\s*ParallelDownloads\s*=.*/ParallelDownloads = 10/' "$PACMAN_CONF"
fi

if grep -q "-march=native" "$MAKEPKG_CONF" &>/dev/null && \
   ! grep -qE "^OPTIONS([^#]*[^!]debug)" "$MAKEPKG_CONF" &>/dev/null; then
	:
else
	sudo sed -i -e 's/-march=x86-64/-march=native/' \
		-e '/^OPTIONS=/ s/\bdebug\b/!debug/' "$MAKEPKG_CONF"
fi

sudo pacman -Suy --noconfirm &>/dev/null

if ! sudo grep -qxF '## VIBRANIUM: Enable interactive prompt' "$SUDOERS_CONF"; then
	echo -e '\n## VIBRANIUM: Enable interactive prompt\nDefaults env_reset,pwfeedback' \
		| sudo tee -a "$SUDOERS_CONF" &>/dev/null
fi

if ! grep -qxF 'nodelay' "$FAILLOCK_CONF"; then
	echo -e 'deny = 5\nnodelay' | sudo tee -a "$FAILLOCK_CONF" &>/dev/null
fi

if ! sudo grep -q '^auth.*pam_unix\.so.*try_first_pass nullok nodelay' "$SYSTEM_AUTH_CONF"; then
	sudo sed -i '/^auth.*pam_unix\.so.*try_first_pass nullok/ s/\(try_first_pass nullok\)/\1 nodelay/' "$SYSTEM_AUTH_CONF"
fi

install_packages
create_directories

./install/install_gtk_themes.sh
./install/install_papirus_icons.sh
./install/install_local_bin.sh

printf "\n%s[VIBRANIUM]%s Setting up config files" "${YELLOW}" "${RESET}"
cp -r ./config/* "$HOME/.config"
sed -i "s/user/$USER/" "$HOME/.config/qt6ct/qt6ct.conf"

ln -sf "$(realpath ./applications/custom)" "$HOME"/.local/share/applications/ >/dev/null
for entry in ./applications/*.desktop ./applications/hidden/*; do
    ln -sf "$(realpath "$entry")" "$HOME/.local/share/applications/" >/dev/null
done

for file in ./install/generate_*; do
	bash "$file"
done


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

ln -s "${THEME_PATH}" "$HOME/.config/vibranium/theme/current" >/dev/null
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


printf "\n%s[VIBRANIUM]%s Installing systemd services" "${YELLOW}" "${RESET}"
enable_system_services
post_install
cleanup

printf "\n%s[VIBRANIUM]%s Installation complete%s" "${YELLOW}" "${GREEN}" "${RESET}"
printf "\n%s[VIBRANIUM]%s Launching vibranium...\n" "${YELLOW}" "${RESET}"
uwsm start hyprland &>/dev/null
# printf "\n%s[VIBRANIUM]%s You can start using Vibranium by typying 'uwsm start hyprland'" "${YELLOW}" "${RESET}"
# printf "\n%s[VIBRANIUM]%s Or you can reboot the machine and then select 'Hyprland (uwsm-managed)' in DM\n" "${YELLOW}" "${RESET}"

printf '\e[?25h'  # show cursor
