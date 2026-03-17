set -l done_marker $VIBRANIUM_STATE/shell.bootstrapped

if not test -f $done_marker
  if not curl -s --max-time 3 https://raw.githubusercontent.com >/dev/null 2>&1
    echo "Setup: no internet connection, skipping plugin install"
    return
  end

  touch $done_marker
  echo "Setup: installing plugin manager..."
  curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
  fisher install jorgebucaran/fisher jorgebucaran/autopair.fish
  echo "Shell setup complete"
end
