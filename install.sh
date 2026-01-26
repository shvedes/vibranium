#!/usr/bin/env bash

set -euo pipefail

LOOKNFEEL_CONF="$HOME/.config/hypr/hyprland.conf.d/look-and-feel.conf"
LOOKNFEEL_OPTS=(
	"animations:enabled:true"
	"decoration:dim_inactive:true"
	"decoration:rounding:0"
	"decoration:blur:enabled:false"
	"decoration:blur:size:5"
	"decoration:shadow:enabled:true"
)

RED=$'\e[0;31m'
YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
GRAY=$'\e[90m'
RESET=$'\e[0m'

export SUDO_PROMPT; SUDO_PROMPT="$(printf '%s[VIBRANIUM]%s Password for %s: ' "$RED" "$RESET" "$USER")"

if [[ "$(id -u)" == 0 ]]; then
	echo "${RED}[ERROR]${RESET} Do not run this as root!"
	exit 1
fi

if ! command -v yay >/dev/null; then
	printf "%s[VIBRANIUM]%s Installing %syay%s\n" \
		"$YELLOW" "$RESET" "$YELLOW" "$RESET"
	printf "%s[VIBRANIUM]%s You might be asked for sudo several times\n" \
		"$YELLOW" "$RESET"
	if ! command -v git >/dev/null; then
		sudo pacman -S git --noconfirm
	fi

	CWD="$(pwd)"
	cd "$(mktemp -d)" || exit
	git clone -q https://aur.archlinux.org/yay
	cd yay || exit
	makepkg -sirc --noconfirm &> /dev/null
    sudo pacman -Rnsc --noconfirm yay-debug &> /dev/null
	cd "$CWD" || exit
fi

# Hide cursor
printf '\e[?25l'

cleanup() {
	yay -Ycc --noconfirm &>/dev/null
	sudo pacman -Scc --noconfirm &>/dev/null
}

install_packages() {
	local packages pkg start_time
    local elapsed pid aur_flag fs

    fs="$(lsblk -f | grep -E \/\$ | awk '{print $2}')"

	mapfile -t packages < ./pkg_list.txt

	# GPU detection
	case "$(lspci | grep VGA)" in
		*"Nvidia"*)
			printf "%s[VIBRANIUM]%s Detected Nvidia GPU\n" "$YELLOW" "$RESET"
			packages+=("nvidia-dkms" "nvidia-utils" "nvidia-settings" "linux-headers" "lib32-nvidia-utils")
			;;
		*Radeon*|*ATI*)
			printf "%s[VIBRANIUM]%s Detected AMD GPU\n" "$YELLOW" "$RESET"
			packages+=(
				"mesa"
				"lib32-mesa"
				"rocm-smi-lib" # Needed for btop gpu load monitoring
                "opencl-mesa"
				"vulkan-radeon"
				"libvdpau-va-gl"
				"lib32-vulkan-radeon"
			)
			;;
		*UHD*|*Iris*|*Arc*)
			printf "%s[VIBRANIUM]%s Detected Intel GPU\n" "$YELLOW" "$RESET"
			packages+=(
				"mesa"
				"libvpl"
				"lib32-mesa"
				"vpl-gpu-rt"
                "opencl-mesa"
				"vulkan-intel"
				"libvdpau-va-gl"
				"libva-intel-driver"
				"lib32-vulkan-intel"
			)
			;;
		*)
			printf "%s[VIBRANIUM]%s No supported GPU detected. Please install GPU drivers manually\n" "$RED" "$RESET"
			printf "%s[VIBRANIUM]%s Think this is a mistake? Open an issue!\n" "$RED" "$RESET"
			printf "%s[VIBRANIUM]%s This will not affect the installation\n" "$YELLOW" "$RESET"
	esac

    case "$fs" in
        btrfs)
            printf "%s[VIBRANIUM]%s BTRFS root found. Adding required drivers to the queue\n" "$YELLOW" "$RESET"
            packages+=("btrfs-progs")
            ;;
    esac

    if lsblk -f | grep -qi ntfs; then
        printf "%s[VIBRANIUM]%s NTFS partition found. Adding required drivers to the queue\n" "$YELLOW" "$RESET"
        packages+=(
            "ntfs-3g"
            # Efibootmgr might be useful
            # when dealing with multiple OSes.
            # So if we found ntfs - we're
            # probably dealing with Windows.
            "efibootmgr"
        )
    fi

	mapfile -t packages < <(printf "%s\n" "${packages[@]}" | sort -u)

	for pkg in "${packages[@]}"; do
		[[ -z "${pkg//[[:space:]]/}" ]] && continue
		[[ "${pkg:0:1}" == "#" ]] && continue

		if ! pacman -Si "$pkg" >/dev/null 2>&1; then
			aur_flag=" (AUR)"
		else
			aur_flag=""
		fi

		printf "\r\033[K%s[VIBRANIUM]%s Installing %s%s%s " \
			"$YELLOW" "$RESET" "$GRAY" "$pkg" "$aur_flag"

		start_time=$(date +%s)

		case "$pkg" in
			"pipewire-jack")
				if pacman -Qq jack2 &>/dev/null; then
					sudo pacman -Rdd jack2 --noconfirm &>/dev/null
				fi
				;;
			*)
				if pacman -Qq "$pkg" &>/dev/null; then
					continue
				fi
				;;
		esac

		yay -S --noconfirm --needed --sudoloop "$pkg" &>/dev/null
		pid=$!

		while kill -0 "$pid" 2>/dev/null; do
			sudo -v; sleep 1
			elapsed=$(( $(date +%s) - start_time ))
			if (( elapsed > 10 )); then
				printf "\r\033[K%s[VIBRANIUM]%s Installing %s%s [%ds] %s" \
					"$YELLOW" "$RESET" "$GRAY" "$pkg$aur_flag" "$elapsed" "$RESET"
			fi
		done

		wait "$pid"
	done

	printf "\r\033[K%s[VIBRANIUM]%s Packages installed\n" "$YELLOW" "$RESET"
}

enable_system_services() {
	local system_services
	local user_services

	system_services=(
		"ly@tty1"
		"power-profiles-daemon"
		"bluetooth"
	)

	user_services=(
		"waybar"
		"cliphist"
		"hypridle"
		"hyprpaper"
        "alacritty"
		"hyprsunset"
		"gnome-polkit"
        "vibranium-startup"
	)

	user_timers=(
		"vibranium-update"
	)

	sudo systemctl -q enable "${system_services[@]}"
    systemctl -q --user enable "${user_services[@]}"

	for timer in "${user_timers[@]}"; do
		systemctl -q --user enable "${timer}.timer"
	done
}

create_directories() {
	mkdir -p \
		"$HOME"/{Downloads,Documents,Pictures,Videos,Music,Templates} \
		"$HOME"/.config/{Vencord,vesktop}/{themes,settings} \
		"$HOME"/.config/heroic/{themes,store} \
		"$HOME/.config/spicetify/Themes/text" \
		"$HOME/.config/hypr/hyprland.conf.d" \
		"$HOME/.local/share/applications" \
		"$HOME/.local/state/vibranium/" \
		"$HOME/.config/vibranium/theme" \
		"$HOME/.config/qt6ct/colors" \
		"$HOME/.config/btop/themes/" \
		"$HOME/.config/discord" \
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
	local ly_ini
	ly_ini="/etc/ly/config.ini"

	# Store Ly's session log in the ~/.cache directory
	sudo sed -i '/^session_log/s/=.*/= .cache\/display_manager.log/' "$ly_ini"
	cp ./config/mimeapps.list "$HOME/.config"

	touch "$HOME/.local/state/vibranium/first-boot"
	echo "suspended" > \
		"$HOME/.local/state/vibranium/night-light"

	printf '{\n\t"SKIP_HOST_UPDATE": true\n}' \
		> "$HOME/.config/discord/settings.json"

	if [ ! -z "$(find /sys/class/backlight -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
		sudo usermod -aG video "$USER"
	fi

    # https://www.reddit.com/r/linuxquestions/comments/t7ze3c/thunar_open_file_in_neovim/
    cp /usr/share/applications/nvim.desktop "$HOME"/.local/share/applications
    sed -e '/Terminal/s/true/false/' \
        -e '/^Exec/s/=/=vb-cmd-terminal /' \
        -i "$HOME"/.local/share/applications/nvim.desktop
}

if ! git branch | grep -q detached; then
    git checkout -q --detach "$(git tag --sort=-creatordate | head -n 1)"
    exec "$0"
    exit 0
fi

sudo -v; clear
# Move VT to the bottom
printf '\e[2J\e[%d;1H' "${LINES:-$(tput lines)}"
cat ./logo.txt

printf "%s[VIBRANIUM]%s Setting up system files\n" "${YELLOW}" "${RESET}"
./install/edit_system_files.sh

printf "%s[VIBRANIUM]%s Setting up kernel modules\n" "${YELLOW}" "${RESET}"
./install/setup_kernel_modules.sh

printf "%s[VIBRANIUM]%s Setting up sysctl options\n" "${YELLOW}" "${RESET}"
./install/setup_sysctl.sh

printf "%s[VIBRANIUM]%s Setting up swap\n" "${YELLOW}" "${RESET}"
./install/setup_zram.sh

printf "%s[VIBRANIUM]%s Setting up tmpfiles.d\n" "${YELLOW}" "${RESET}"
./install/setup_tmpfiles.d.sh

printf "%s[VIBRANIUM]%s Refreshing repositories\n" "${YELLOW}" "${RESET}"
sudo pacman -Suy --noconfirm &>/dev/null

install_packages
create_directories

./install/install_core_pkgs.sh
./install/install_gtk_themes.sh
./install/install_papirus_icons.sh
./install/install_local_bin.sh
./install/install_sound_theme.sh

printf "\n%s[VIBRANIUM]%s Setting up config files" "${YELLOW}" "${RESET}"

ln -sf "$(realpath ./applications/custom)" "$HOME"/.local/share/applications/ >/dev/null
for entry in ./applications/*.desktop ./applications/hidden/*; do
    ln -sf "$(realpath "$entry")" "$HOME/.local/share/applications/" >/dev/null
done

for opt in "${LOOKNFEEL_OPTS[@]}"; do
	./bin/vb-cmd-edit-wm-config "$opt" "$LOOKNFEEL_CONF"
done

for file in ./install/generate_*; do
	bash "$file"
done

printf "\n%s[VIBRANIUM]%s Setting default theme" "${YELLOW}" "${RESET}"
./install/set_default_theme.sh

printf "\n%s[VIBRANIUM]%s Installing systemd services" "${YELLOW}" "${RESET}"
enable_system_services

printf "\n%s[VIBRANIUM]%s Applying systemd units overrides" "${YELLOW}" "${RESET}"
./install/set_systemd_overrides.sh

printf "\n%s[VIBRANIUM]%s Cleaning up" "${YELLOW}" "${RESET}"
post_install
cleanup

printf "\n%s[VIBRANIUM]%s Installation complete. System restart required" "${GREEN}" "${RESET}"
printf "\n%s[VIBRANIUM]%s After rebooting don't forget to select %sHyprland (uwsm-managed)%s in the login box\n" \
	"$YELLOW" "$RESET" "$GRAY" "$RESET"

prompt=$'\e[0;33m[VIBRANIUM]\e[0m Restart now? (Y/n): '
while :; do
	printf "%s\e[?25h" "$prompt"
	read -r answer
	printf '\e[?25l'

	case "$answer" in
		[Yy][Ee][Ss]|[Yy]|"")
			printf '\e[?25l'
			for i in {3..1}; do
				printf "\r\033[K%s[VIBRANIUM]%s Restarting in %d..." "$YELLOW" "$RESET" "$i"
				sleep 1
			done
			systemctl reboot
			;;
		[Nn][Oo]|[Nn])
			break
			;;
		*)
			printf '\r\e[K'
			;;
	esac
done

printf '\e[?25h'  # show cursor
