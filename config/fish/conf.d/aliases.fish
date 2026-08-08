if command -q eza
    alias l="eza --hyperlink=auto"
    alias ls="ezaa --hyperlink=auto"
    alias sl="eza --hyperlink=auto"
    alias ll="eza -lhbg@ --group-directories-first --hyperlink=auto"
    alias la="eza -ahbg@ --group-directories-first --hyperlink=auto"
    alias lla="eza -alhbg@ --group-directories-first --hyperlink=auto"
    alias tree="eza --tree --hyperlink=auto"
end

if command -q trash
    alias rm="trash -v"
end

if command -q imv
    alias imv="imv-dir"
end

alias ip="ip --color"

if set -q VIBRANIUM_STATE; and test -f "$VIBRANIUM_STATE/update.available"
    alias update-vibranium="xdg-terminal-exec --app-id=org.vb.term.float --title=vb-update -- vb-update"
end

alias omarchy-theme-install="vb-theme-install"
alias vibranium-healthcheck="vb-cmd-healthcheck"
alias wget="wget --hsts-file=\$XDG_DATA_HOME/wget-hsts"
