#!/bin/bash

SUDOERS_CONF="/etc/sudoers.d/vibranium"
FAILLOCK_CONF="/etc/security/faillock.conf"
SYSTEM_AUTH_CONF="/etc/pam.d/system-auth"

helpers::log::info "Configuring sudo & pam"

if [[ ! -d /etc/sudoers.d ]]; then
  sudo mkdir /etc/sudoers.d
fi

helpers::append_once "$SUDOERS_CONF" \
  '## VIBRANIUM: Enable interactive prompt' \
  $'\n## VIBRANIUM: Enable interactive prompt\nDefaults env_reset,pwfeedback'

helpers::append_once "$FAILLOCK_CONF" 'nodelay' $'deny = 5\nnodelay'

sudo grep -q '^auth.*pam_unix\.so.*try_first_pass nullok nodelay' "$SYSTEM_AUTH_CONF" ||
  helpers::sed "$SYSTEM_AUTH_CONF" -E '/^auth.*pam_unix\.so.*try_first_pass nullok/ s/\bnullok\b/& nodelay/'
