if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/bash/states/silent" ]]; then
  return 0
fi

echo "Edit config in: ${YELLOW}~/.bash${RESET}"
echo "Hide this message: ${GREEN}toggle-startup-message${RESET}"
echo "List additional shell functions: ${GREEN}flist${RESET}"
echo "Bash documentation: ${GREEN}man ${YELLOW}bash${RESET}"

if ! [[ -c /dev/tty && $TERM == linux ]]; then
  if [[ -n "$VIBRANIUM_STATE" && -f "$VIBRANIUM_STATE/update.available" ]]; then
    echo "Vibranium update available! Run: ${GREEN}update-vibranium${RESET}"
  fi
fi

echo

if [[ -f $VIBRANIUM_STATE/errors_found ]]; then
  echo "Vibrainum errors found!"
  echo "Type ${GREEN}vibranium-healthcheck${RESET} to repair"
  echo
fi
