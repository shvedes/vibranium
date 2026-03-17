if command -q eza
  alias ls="eza -XM"
  alias ll="eza -XMhml --no-filesize --smart-group --time-style='+%y-%m-%d %H:%M'"
  alias la="eza -1lXMhA --no-filesize --smart-group --time-style='+%y-%m-%d %H:%M'"
  alias tree="eza --tree"
end

alias imv="imv-dir"
alias ip="ip --color"

if test -f $VIBRANIUM_STATE/update.available
  alias update-vibranium="vb-core-term --floating -- vb-update"
end
