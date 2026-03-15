#!/usr/bin/env bash

_log_info "Vibranium includes auxiliary scripts that patch ${CYAN}Discord${RESET} and ${GREEN}Spotify${RESET}"
_log_info "during installation and updates."

_log_info "${CYAN}Vencord${RESET} is a portable tool used to patch ${CYAN}Discord${RESET}, enabling additional settings,"
_log_info "a plugin system, UI themes, and more. It does not require installation."

_log_info "${YELLOW}spicetify${RESET} is used to patch ${GREEN}Spotify${RESET}, enabling custom plugins,"
_log_info "themes, and a community-driven marketplace. Note that ${YELLOW}spicetify${RESET} is not installed by default;"
_log_info "the patch will only work if you install it manually."

if ! term::ask_yes_no Y "Would you like to keep the Discord patcher?"; then
  UpdateSummary "libalpm / hooks: removed pacman hook for automatic Discord patching (user choice)"
  touch /tmp/vibranium-remove-vencord
fi

if ! term::ask_yes_no Y "Would you like to keep the Spotify patcher?"; then
  UpdateSummary "libalpm / hooks: removed pacman hook for automatic Spotify patching (user choice)"
  touch /tmp/vibranium-remove-spicetify
fi
