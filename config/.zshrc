# Do not remove this code. It sources custom Vibranium
# configurations. If you remove it, your shell will
# start without custom configuration.

if [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/zsh" ]]; then
  source "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/init.zsh"
else
  echo "Warning: missing zsh config (${XDG_CONFIG_HOME:-$HOME/.config}/zsh)"
  echo "Using default shell setup"
fi

# Your overrides start here.
