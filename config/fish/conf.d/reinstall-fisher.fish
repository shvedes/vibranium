if not test -f $XDG_CONFIG_HOME/fish/functions/fisher.fish
  function fix-shell
    rm -f $XDG_CONFIG_HOME/fish/first-run
    rm -f $XDG_CONFIG_HOME/fish/functions/fisher.fish
    rm -f $XDG_CONFIG_HOME/fish/conf.d/fisher.fish
    InstallFisher
    # Remove this function
    # from the session
    functions -e fix-shell
  end
end
