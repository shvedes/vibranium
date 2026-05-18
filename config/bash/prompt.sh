# Use starship if available
if command -v starship >/dev/null; then
  eval -- "$(/usr/bin/starship init bash --print-full-init)"
  return 0
fi

echo "${YELLOW}Warning${RESET}: starship not found, using fallback prompt"
