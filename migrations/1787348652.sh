#!/bin/bash
#
# Quickshell migration: retire the Waybar/Rofi/Dunst stack and bring up
# vibranium-shell. Idempotent: safe to re-run (the migrate runner retries
# scripts that crashed before their success marker was written).

set -u

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

: "${VIBRANIUM:=$HOME/.local/share/vibranium}"

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

# Migrations run outside the installer, where the XDG vars are not exported;
# fall back to the spec defaults so the paths never collapse to "/applications".
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
mkdir -p "$data_dir/applications" "$config_dir/systemd/user" || exit 1

# Full system upgrade first, while the old network stack is still up.
# Non-fatal: a conflict should not block the shell switch below.
if ! sudo pacman -Suy --noconfirm; then
	echo "${GREEN}[MIGRATION|$SELF]${RESET} system upgrade failed, continuing with the shell switch" >&2
fi

# Stop the old per-user units. Each is tolerant: units may already be gone
# on re-run, and systemd returns non-zero for unknown units.
for unit in gnome-polkit.service cliphist.service hypridle.service swayosd.service waybar.service awww.service; do
	systemctl -q --user disable --now "$unit" || true
done

# Only pass installed packages to pacman: without this filter a single
# already-removed package makes the whole removal fail. No --cascade (-c):
# it would pull user packages that merely depend on one of these targets.
installed=()
for p in "${pkg_to_remove[@]}"; do
	if pacman -Qq "$p" &> /dev/null; then
		installed+=("$p")
	fi
done
if (( ${#installed[@]} > 0 )); then
	sudo pacman -Rns --noconfirm "${installed[@]}" || true
fi

# Quickshell itself. Fatal: without it there is no bar, lock, or launcher.
if ! vb-pkg-install --embedded -- quickshell; then
	echo "${GREEN}[MIGRATION|$SELF]${RESET} quickshell install failed" >&2
	exit 1
fi

# Bring NetworkManager up BEFORE stopping the old network stack, so the
# later steps (and the user) never sit without connectivity. The shell's
# connectivity watcher reads NetworkManager over D-Bus, so NM is required.
sudo systemctl -q enable --now NetworkManager.service || true
sudo systemctl -q disable --now systemd-networkd iwd || true

# Stale entries left behind by already-copied desktop files whose sources
# were deleted or renamed (imv/satty removed, power-* removed,
# rofi.desktop renamed to xfce4-about.desktop, vb-util-calc removed from
# custom). Never touch image-viewer.desktop here: it is installed below.
rm -f "$data_dir"/applications/imv.desktop
rm -f "$data_dir"/applications/satty.desktop
rm -f "$data_dir"/applications/vb-util-calc.desktop
rm -f "$data_dir"/applications/rofi.desktop
rm -f "$data_dir"/applications/rofi-theme-selector.desktop
rm -f "$data_dir"/applications/power-*.desktop

# Mirror install/post-install/00-configs.sh so migrated installs end up
# identical to fresh ones.

# Top-level entries install unconditionally.
for entry in "$VIBRANIUM"/applications/*.desktop; do
	[[ -e "$entry" ]] || continue
	cp -a --no-preserve=ownership "$entry" "$data_dir/applications/${entry##*/}" || exit 1
done

# Custom entries are conditional: the shell cannot evaluate TryExec, so an
# entry whose backing executable is absent would linger as a dead row.
_tryexec_present() {
	[[ -z "$1" ]] && return 0
	command -v "$1" > /dev/null && return 0
	[[ -x "$VIBRANIUM/bin/$1" ]] && return 0
	return 1
}
for entry in "$VIBRANIUM"/applications/custom/*.desktop; do
	[[ -e "$entry" ]] || continue
	base="${entry##*/}"
	tryexec="$(sed -n 's/^TryExec=//p' "$entry" | head -n1)"
	if ! _tryexec_present "$tryexec"; then
		rm -f "$data_dir/applications/$base"
		continue
	fi
	cp -a --no-preserve=ownership "$entry" "$data_dir/applications/$base" || exit 1
done

# Hidden entries (foot, foot-server, footclient, xfce4-about, ...) install
# unconditionally; they are NoDisplay overrides, not launcher rows.
for entry in "$VIBRANIUM"/applications/hidden/*.desktop; do
	[[ -e "$entry" ]] || continue
	cp -a --no-preserve=ownership "$entry" "$data_dir/applications/${entry##*/}" || exit 1
done

if command -v update-desktop-database &> /dev/null; then
	update-desktop-database "$data_dir/applications" || true
fi

# Point image mimetypes at the shell viewer the way fresh installs do
# (install/first-run/11-mimetype.sh), instead of sed-editing mimeapps.list.
if command -v xdg-mime &> /dev/null; then
	for mime in image/jpeg image/png image/webp image/gif image/avif \
		image/heif image/heic image/svg+xml \
		image/vnd.adobe.photoshop image/x-psd \
		image/x-canon-cr2 image/x-nikon-nef; do
		xdg-mime default image-viewer.desktop "$mime" || true
	done
fi

# Advertise the new user unit before enabling it; without the reload the
# just-copied file may not resolve and enable would fail.
cp -a --no-preserve=ownership \
	"$VIBRANIUM"/config/systemd/user/vibranium-shell.service \
	"$config_dir"/systemd/user/ || exit 1
systemctl --user daemon-reload || true
systemctl -q --user enable --now vibranium-shell.service || true

exit 0
