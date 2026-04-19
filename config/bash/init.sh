# If not running interactively, don't do anything
if [[ $- != *i* ]]; then
  return
fi

YELLOW=$'\e[0;33m'
RESET=$'\e[0m'
GREEN=$'\e[0;32m'

source "${XDG_CONFIG_HOME:-$HOME/.config}"/bash/install_plugins.sh

for f in "${XDG_CONFIG_HOME:-$HOME/.config}"/bash/{plugins,functions,aliases,abbreviations}/*.sh; do
  source "$f"
done

source "${XDG_CONFIG_HOME:-$HOME/.config}"/bash/greeting.sh
source "${XDG_CONFIG_HOME:-$HOME/.config}"/bash/prompt.sh
source "${XDG_CONFIG_HOME:-$HOME/.config}"/bash/binds.sh
