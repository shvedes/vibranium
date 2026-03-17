if command -q eza
  alias ls="eza -XM"
  alias ll="eza -XMhml --no-filesize --smart-group --time-style='+%y-%m-%d %H:%M'"
  alias la="eza -1lXMhA --no-filesize --smart-group --time-style='+%y-%m-%d %H:%M'"
  alias tree="eza --tree"
end

if not command -q nmtui
  abbr restart-network "sudo systemctl restart iwd systemd-{network,resolve}d"
end

abbr restart-pipewire "systemctl --user restart pipewire pipewire-pulse wireplumber"

alias imv="imv-dir"
alias ip="ip --color"
