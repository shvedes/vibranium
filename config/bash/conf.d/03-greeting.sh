if [[ -f "$BASH_CONFIG_DIR/.silent" ]]; then
  return 0
fi

print << EOF
Edit config in: ${YEL}~/.config/bash${RST}
Hide this message: ${GRN}toggle-startup-message${RST}
Bash documentation: ${GRN}man ${YEL}bash${RST}
Registered aliases: ${GRN}alias${RST}

EOF

if ! [[ -c /dev/tty && $TERM == linux ]]; then
  if [[ -n "$VIBRANIUM_STATE" && -f "$VIBRANIUM_STATE/update.available" ]]; then
    echo -e "Vibranium update available! Update in the settings.\n"
  fi
fi

if [[ ! -z $VIBRANIUM && -f $VIBRANIUM_STATE/errors_found ]]; then
  echo -e "Vibranium ${RED}errors${RST} found! Type ${GRN}vibranium-healthcheck${RST} to repair.\n"
fi
