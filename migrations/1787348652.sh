#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

pkg_to_remove=(
	"polkit-gnome"
	"rofi-emoji"
	"wttrbar-bin"
	"hyprpicker"
	"rofi-calc"
	"hyprlock"
	"hypridle"
	"cliphist"
	"swayosd"
	"waybar"
	"slurp"
	"satty"
	"dunst"
	"rofi"
	"awww"
	"grim"
	"imv"
)

# Update the system first.
sudo pacman -Suy --noconfirm

systemctl -q --user disable --now \
	gnome-polkit.service \
	cliphist.service \
	hypridle.service \
	swayosd.service \
	waybar.service \
	awww.service

sudo pacman -Rnsc --noconfirm "${pkg_to_remove[@]}"

vb-pkg-install --embedded -- quickshell

# Migrations run outside the installer, where the XDG vars are not exported;
# fall back to the spec defaults so the paths never collapse to "/applications".
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"

rm -f "$data_dir"/applications/imv.desktop
rm -f "$data_dir"/applications/satty.desktop
rm -f "$data_dir"/applications/vb-util-calc.desktop
rm -f "$data_dir"/applications/image-viewer.desktop
rm -rf "$data_dir"/applications/power-*.desktop

cp "$VIBRANIUM"/applications/Image\ Viewer.desktop "$data_dir"/applications
cp "$VIBRANIUM"/applications/foot.desktop "$data_dir"/applications
cp "$VIBRANIUM"/config/systemd/user/vibranium-shell.service \
	"$config_dir"/systemd/user

sed -i 's/imv-dir/image-viewer/g' ~/.config/mimeapps.list
sed -i 's/imv/image-viewer/g' ~/.config/mimeapps.list

sudo systemctl -q disable --now systemd-networkd iwd

sudo systemctl -q enable --now NetworkManager.service

systemctl -q --user enable --now vibranium-shell.service
