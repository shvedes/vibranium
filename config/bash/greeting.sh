if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/bash/.greeting.disabled" ]]; then
  return 0
fi

echo "Apply changes in ${YELLOW}~/.bashrc${RESET}"
echo "Toggle this message: ${GREEN}toggle-startup-message${RESET}"
echo "List additional shell functions: ${GREEN}flist${RESET}"
echo "Bash documentation: ${GREEN}man bash${RESET}"

if ! [[ -c /dev/tty && $TERM == linux ]]; then
  if [[ -n "$VIBRANIUM_STATE" && -f "$VIBRANIUM_STATE/update.available" ]]; then
    echo "Vibranium update available! Run: ${GREEN}update-vibranium${RESET}"
  fi
fi
