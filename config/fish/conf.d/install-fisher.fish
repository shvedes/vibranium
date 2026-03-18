if not status is-interactive
  return
end

set -l first_run_marker $XDG_CONFIG_HOME/fish/first-run

if not functions -q fisher
  function InstallFisher
    if not curl -s --max-time 3 https://raw.githubusercontent.com >/dev/null 2>&1
      echo "Setup: no internet connection, skipping plugin install"
      return
    end

    echo "Shell: installing plugin manager..."
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source

    echo "Shell: installing 2 plugins..."
    fisher install jorgebucaran/fisher jorgebucaran/autopair.fish &> /dev/null

    echo "Shell: setup complete!"

    if functions -q fix-shell
      functions -e fix-shell
    end
  end
end

if test -f $first_run_marker
  rm -f $first_run_marker
  InstallFisher
  clear
else
  # Double check
  if not test -f $XDG_CONFIG_HOME/fish/functions/fisher.fish
    echo (set_color red)"Warning:"(set_color normal)" missing fish plugin manager! Try "(set_color green)"fix-shell"(set_color normal)
    echo
  end
end
