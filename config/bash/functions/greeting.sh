
function toggle-startup-message() {
  local usage='Usage: toggle-startup-message

Toggle the startup message on or off.

Options:
  -h, --help              display this help and exit'

  if [[ $1 == -h || $1 == --help ]]; then
    printf '%s\n' "$usage"
    return 0
  fi

  if [[ -f "$BASH_CONFIG_DIR/.silent" ]]; then
    command rm -f -- "$BASH_CONFIG_DIR/.silent"
    printf '%s\n' "Startup message ${GRN}enabled${RST}"
  else
    : > "$BASH_CONFIG_DIR/.silent"
    printf '%s\n' "Startup message ${RED}disabled${RST}"
  fi
}
