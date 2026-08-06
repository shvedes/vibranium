# shellcheck disable=all

# If not running interactively, don't do anything
if [[ $- != *i* ]]; then
  return
fi

# Don't throw error when globs don't expand.
shopt -s nullglob

YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
RED=$'\e[0;31m'
RESET=$'\e[0m'

# Use :- in case if launched in TTY
BASH_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bash"

# Create history folder / file if doesn't exist yet.
# bash does not create it automatically, so cover it.
if ! [[ -d "${XDG_DATA_HOME:-$HOME/.local/state}/bash" ]]; then
  mkdir -p "${XDG_DATA_HOME:-$HOME/.local/state}/bash"
  : > "${XDG_DATA_HOME:-$HOME/.local/state}/bash/history"
fi

source "$BASH_CONFIG_DIR/functions.sh"
source "$BASH_CONFIG_DIR/greeting.sh"
source "$BASH_CONFIG_DIR/aliases.sh"
source "$BASH_CONFIG_DIR/prompt.sh"
source "$BASH_CONFIG_DIR/binds.sh"
