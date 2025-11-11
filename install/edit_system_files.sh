#!/usr/bin/env bash

PACMAN_CONF="/etc/pacman.conf"
MAKEPKG_CONF="/etc/makepkg.conf"
SUDOERS_CONF="/etc/sudoers"
FAILLOCK_CONF="/etc/security/faillock.conf"
SYSTEM_AUTH_CONF="/etc/pam.d/system-auth"
LOGIND_CONF="/etc/systemd/logind.conf"

sudo cp -r ./extras/usr/local/bin/*  /usr/local/bin/
sudo cp -r ./extras/etc/*            /etc/

sudo sed -Ei '/^#?HandlePowerKey=/s/^#//;s/=.*/=ignore/' "$LOGIND_CONF"

grep -qE '^\[multilib\]' "$PACMAN_CONF" ||
sudo sed -Ei '/\[multilib\]/,/^$/s/^#//' "$PACMAN_CONF"
sudo sed -i '/^#NoExtract/ s/^#//' "$PACMAN_CONF"
sudo sed -i '/^NoExtract/ s|$| usr/lib/thunarx-3/thunar-wallpaper-plugin.so|' "$PACMAN_CONF"

grep -q '^Color' "$PACMAN_CONF" ||
sudo sed -Ei 's/^\s*#?Color/Color/' "$PACMAN_CONF"

grep -q '^VerbosePkgLists' "$PACMAN_CONF" ||
sudo sed -Ei 's/^\s*#?VerbosePkgLists/VerbosePkgLists/' "$PACMAN_CONF"

grep -q '^ParallelDownloads = 10' "$PACMAN_CONF" ||
sudo sed -Ei 's/^\s*#?ParallelDownloads.*/ParallelDownloads = 10/' "$PACMAN_CONF"

grep -q '\-march=native' "$MAKEPKG_CONF" ||
sudo sed -Ei 's/-march=x86-64/-march=native/' "$MAKEPKG_CONF"

grep -Eq '^OPTIONS=.*\bdebug\b' "$MAKEPKG_CONF" &&
sudo sed -Ei '/^OPTIONS=/ s/\b!*\bdebug\b/!debug/' "$MAKEPKG_CONF"

sudo grep -qxF '## VIBRANIUM: Enable interactive prompt' "$SUDOERS_CONF" ||
echo -e '\n## VIBRANIUM: Enable interactive prompt\nDefaults env_reset,pwfeedback' |
sudo tee -a "$SUDOERS_CONF" >/dev/null

grep -qxF 'nodelay' "$FAILLOCK_CONF" ||
echo -e 'deny = 5\nnodelay' | sudo tee -a "$FAILLOCK_CONF" >/dev/null

sudo grep -q '^auth.*pam_unix\.so.*try_first_pass nullok nodelay' "$SYSTEM_AUTH_CONF" ||
sudo sed -Ei '/^auth.*pam_unix\.so.*try_first_pass nullok/ s/\bnullok\b/& nodelay/' "$SYSTEM_AUTH_CONF"

