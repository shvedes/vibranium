
# Navigation
bindkey '^A' beginning-of-line       # Ctrl+A
bindkey '^E' end-of-line             # Ctrl+E
bindkey '^B' backward-char           # Ctrl+B
bindkey '^F' forward-char            # Ctrl+F

# Word navigation
bindkey '^[b' backward-word          # Alt+B
bindkey '^[f' forward-word           # Alt+F

# History navigation
bindkey '^P' up-line-or-history      # Ctrl+P
bindkey '^N' down-line-or-history    # Ctrl+N

# Editing
bindkey '^U' backward-kill-line      # Ctrl+U
bindkey '^K' kill-line               # Ctrl+K
bindkey '^W' backward-kill-word      # Ctrl+W
bindkey '^[^?' backward-kill-word    # Alt+Backspace

bindkey '^R' history-incremental-search-backward   # Ctrl+R
bindkey '^S' history-incremental-search-forward    # Ctrl+S (forward search)

# Clear screen
bindkey '^L' clear-screen

# Prefix-aware history search
autoload -U up-line-or-beginning-search
autoload -U down-line-or-beginning-search

zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search

# terminfo keys
[[ -n "${terminfo[kcuu1]}" ]] && bindkey "${terminfo[kcuu1]}" up-line-or-beginning-search
[[ -n "${terminfo[kcud1]}" ]] && bindkey "${terminfo[kcud1]}" down-line-or-beginning-search

# Hardcoded ANSI fallback
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
