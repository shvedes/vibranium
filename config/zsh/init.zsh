# If not running interactively, don't do anything
if [[ $- != *i* ]]; then 
  return
fi

# Don't throw error when globs don't expand.
setopt null_glob

YELLOW=$'\e[0;33m'
GREEN=$'\e[0;32m'
RED=$'\e[0;31m'
RESET=$'\e[0m'

ZSH_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"

export HISTFILE="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/history"
export HISTSIZE=100000
export SAVEHIST=100000

setopt SHARE_HISTORY            # read/write history in real-time across all sessions
setopt HIST_IGNORE_DUPS         # don't record a command identical to the previous one
setopt HIST_IGNORE_ALL_DUPS     # remove older duplicate entries from history
setopt HIST_FIND_NO_DUPS        # don't show duplicates when searching
setopt HIST_IGNORE_SPACE        # don't record commands starting with a space
setopt HIST_REDUCE_BLANKS       # strip unnecessary whitespace before saving
setopt EXTENDED_HISTORY         # save timestamp + duration with each entry

# Ensure history directory exists
local hist_dir="${HISTFILE:h}"

if [[ ! -d "$hist_dir" ]]; then
  command mkdir -p "$hist_dir"
fi

# Source pre-prompt logic first
source "$ZSH_CONFIG_DIR/conf.d/plugins.zsh"

for f in "$ZSH_CONFIG_DIR"/{plugins,functions,aliases}/*.zsh(.N); do
  source "$f"
done

source "$ZSH_CONFIG_DIR/greeting.zsh"
source "$ZSH_CONFIG_DIR/prompt.zsh"
source "$ZSH_CONFIG_DIR/binds.zsh"
