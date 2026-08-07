if command -q eza
    alias ls="eza -XM"
    alias ll="eza -XMhml --no-filesize --smart-group --time-style='+%y-%m-%d %H:%M'"
    alias la="eza -1lXMhA --no-filesize --smart-group --time-style='+%y-%m-%d %H:%M'"
    alias tree="eza --tree"
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
