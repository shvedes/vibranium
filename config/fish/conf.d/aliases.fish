if command -q eza
    alias ls="eza -XM"
    alias ll="eza -XMhml --no-filesize --smart-group --time-style='+%y-%m-%d %H:%M'"
    alias la="eza -1lXMhA --no-filesize --smart-group --time-style='+%y-%m-%d %H:%M'"
    alias tree="eza --tree"
end

if command -q trash
    alias rm="trash -v"
end

alias imv="imv-dir"
alias ip="ip --color"

if test -f $VIBRANIUM_STATE/update.available
    alias update-vibranium="xdg-terminal-exec --app-id=org.vb.term.float --title=vb-update -- vb-update"
end
