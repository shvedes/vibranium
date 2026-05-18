# Do not remove this code. It sources custom Vibranium
# configurations. If you remove it, your shell will
# start without custom configuration.

if [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/bash" ]]; then
  source "${XDG_CONFIG_HOME:-$HOME/.config}/bash/init.sh"
else
  echo "Warning: missing bash config (${XDG_CONFIG_HOME:-$HOME/.config}/bash)"
  echo "Using default shell setup"
fi

# Your overrides start here.
