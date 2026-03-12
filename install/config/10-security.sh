#!/usr/bin/env bash

SUDOERS_CONF="/etc/sudoers.d/vibranium"
FAILLOCK_CONF="/etc/security/faillock.conf"
SYSTEM_AUTH_CONF="/etc/pam.d/system-auth"

if [[ ! -d /etc/sudoers.d ]]; then
    sudo mkdir /etc/sudoers.d
fi

# sudo: show asterisk symbols when entering a password
sudo grep -qxF '## VIBRANIUM: Enable interactive prompt' "$SUDOERS_CONF" 2> /dev/null ||
echo -e '\n## VIBRANIUM: Enable interactive prompt\nDefaults env_reset,pwfeedback' |
sudo tee -a "$SUDOERS_CONF" >/dev/null

# Increase failed sudo attempts to five
grep -qxF 'nodelay' "$FAILLOCK_CONF" ||
echo -e 'deny = 5\nnodelay' | sudo tee -a "$FAILLOCK_CONF" >/dev/null

# Completely remove delay between sudo attempts after entering wrong password
sudo grep -q '^auth.*pam_unix\.so.*try_first_pass nullok nodelay' "$SYSTEM_AUTH_CONF" ||
sudo sed -Ei '/^auth.*pam_unix\.so.*try_first_pass nullok/ s/\bnullok\b/& nodelay/' "$SYSTEM_AUTH_CONF"
