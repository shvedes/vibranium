
# Force emacs-style editing: EDITOR=nvim would otherwise make zsh auto-link
# the main keymap to viins (vi mode), losing most default bindings.
bindkey -e

# Use fish-like ^W word deletion.
# When used with paths, it deletes the closest word instead of the full path.

# Disable tty-level word-erase handling so Ctrl+W reaches zle instead
# of being consumed by the terminal driver first.
stty werase undef

# Rebind Ctrl+W to stop at slashes, not just whitespace.
# Drop '/' from WORDCHARS so path components are separate words.
WORDCHARS='*?_-.[]~=&;!#$%^()+{}'
bindkey '^W' backward-kill-word

# ^P/^N: fish-like history cycling. With an empty buffer they recall
# sequentially; with typed text they filter history by prefix.
bindkey '^P' history-beginning-search-backward
bindkey '^N' history-beginning-search-forward

# ^E: accept the autosuggestion if one is shown, otherwise move the cursor
# to the end of the line (like bash/fish).
if (( ${+widgets[autosuggest-accept]} )); then
  _zsh_end_of_line_accept() {
    if [[ -n ${POSTDISPLAY-} ]]; then
      zle autosuggest-accept
    else
      zle end-of-line
    fi
  }
  zle -N _zsh_end_of_line_accept
  bindkey '^E' _zsh_end_of_line_accept
else
  bindkey '^E' end-of-line
fi
