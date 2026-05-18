# Fish shell–like TAB completion behavior

# Automatically append a trailing "/" when completing directories
# e.g. typing "cd Dow<TAB>" -> "cd Downloads/"
setopt AUTO_PARAM_SLASH

# Enable menu-style completion:
# pressing TAB repeatedly cycles through matches instead of inserting all at once
setopt MENU_COMPLETE

# Turn on interactive selection menu for completions
# allows arrow keys / TAB cycling through options
zstyle ':completion:*' menu select

# Custom prompt shown when scrolling through completion menu
# %S / %s = standout mode (highlight on/off)
# %p = current position (index) in the list
zstyle ':completion:*' select-prompt '%SScrolling active: current selection at %p%s'

# Case-insensitive matching:
# treats lowercase and uppercase letters as equivalent during completion
# e.g. "doc<TAB>" matches "Documents"
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
