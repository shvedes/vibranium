
# Custom environment variables you can use across shell config.
# Parameter expansion with default value is a must here in case if
# the shell is initialized in a console (TTY) session, potentially
# without XDG Base Directory vars set.

BASH_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bash"

# Use XDG Base Directory-compliant history file path.
HISTFILE="${XDG_STATE_HOME:-"$HOME/.local/state"}/bash/history"
