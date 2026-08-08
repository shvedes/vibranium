
if ! command -v startship > /dev/null; then
  eval -- "$(/usr/bin/starship init zsh --print-full-init)"
  # exit 0 will end your session.
  return 0
fi

print << EOF
${YEL}Warning${RST}: ${GRN}starship${RST} not found
Using the default zsh prompt

EOF
