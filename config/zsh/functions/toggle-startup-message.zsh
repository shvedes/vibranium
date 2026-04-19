function toggle-startup-message() {
  if [[ -f "$ZSH_CONFIG_DIR/states/silent" ]]; then
    command rm -f "$ZSH_CONFIG_DIR/states/silent"
    echo "Startup message ${GREEN}enabled${RESET}"
  else
    if [[ ! -d "$ZSH_CONFIG_DIR/states" ]]; then
      mkdir -p "$ZSH_CONFIG_DIR/states"
    fi

    : >"$ZSH_CONFIG_DIR/states/silent"
    echo "Startup message ${RED}disabled${RESET}"
  fi
}
