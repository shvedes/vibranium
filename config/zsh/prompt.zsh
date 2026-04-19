# Use starship if available
if command -v starship >/dev/null; then
  eval "$(/usr/bin/starship init zsh)"
  return 0
fi

echo "${YELLOW}Warning${RESET}: starship not found, using fallback prompt"
source /usr/share/zsh/functions/Prompts/prompt_bart_setup
