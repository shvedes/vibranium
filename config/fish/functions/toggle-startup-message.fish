function toggle-startup-message --description "Toggle startup greeting message"
    if not test -f $XDG_CONFIG_HOME/fish/states/silent
        : >$XDG_CONFIG_HOME/fish/states/silent
        echo "Shell greeting "(set_color red)"disabled"(set_color normal)
    else
        command rm -f $XDG_CONFIG_HOME/fish/states/silent
        echo "Shell greeting "(set_color green)"enabled"(set_color normal)
    end
end
