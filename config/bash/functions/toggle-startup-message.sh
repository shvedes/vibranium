function toggle-startup-message() {
  if [[ -f "$BASH_CONFIG_DIR/states/silent" ]]; then
    command rm -f "$BASH_CONFIG_DIR/states/silent"
    echo "Startup message ${GREEN}enabled${RESET}"
  else
    if [[ ! -d "$BASH_CONFIG_DIR/states" ]]; then
      mkdir -p "$BASH_CONFIG_DIR/states"
    fi

    : >"$BASH_CONFIG_DIR/states/silent"
    echo "Startup message ${RED}disabled${RESET}"
  fi
}
