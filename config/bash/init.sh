# If not running interactively, don't do anything
if [[ $- != *i* ]]; then
  return
fi

# Don't throw error
# when globs don't expand.
shopt -s nullglob

YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
RED=$'\e[0;31m'
RESET=$'\e[0m'

BASH_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bash"

for f in "$BASH_CONFIG_DIR"/{functions,aliases}/*.sh; do
  source "$f"
done

source "$BASH_CONFIG_DIR/greeting.sh"
source "$BASH_CONFIG_DIR/prompt.sh"
source "$BASH_CONFIG_DIR/binds.sh"
