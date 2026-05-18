if not test -f $__fish_config_dir/fish/functions/fisher.fish
    function fix-shell
        rm -f $__fish_config_dir/fish/first-run
        rm -f $__fish_config_dir/fish/functions/fisher.fish
        rm -f $__fish_config_dir/fish/conf.d/fisher.fish
        InstallFisher
        # Unload from the session
        functions -e fix-shell
    end
end
