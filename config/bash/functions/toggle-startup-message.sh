function toggle-startup-message() {
  if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/bash/greeting-disabled" ]]; then
    command rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/bash/greeting-disabled"
    echo "Startup message enabled"
  else
    touch "${XDG_CONFIG_HOME:-$HOME/.config}/bash/greeting-disabled"
    echo "Startup message disabled"
  fi
}
