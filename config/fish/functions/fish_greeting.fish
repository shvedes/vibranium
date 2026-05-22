function fish_greeting
    if not test -f $XDG_CONFIG_HOME/fish/states/silent
        echo "Edit config in: "(set_color yellow)"~/.config/fish/config.fish"(set_color normal)
        echo "Hide this message: "(set_color green)"toggle-startup-message"(set_color normal)
        echo "List additional shell functions: "(set_color green)"flist"(set_color normal)

        if functions -q fisher
            echo "Fish plugin manager: "(set_color green)"fisher " (set_color cyan)"--help"$(set_color normal)
        end

        echo "Fish shell documentation: "(set_color green)"help"(set_color normal)

        if set -q VIBRANIUM_STATE
            if test -f "$VIBRANIUM_STATE/update.available"
                echo "New update available! Run "(set_color green)"update-vibranium"(set_color normal)" to update"
            end
        end
        echo
    end
end

if test -f $VIBRANIUM_STATE/errors_found
  echo "Vibrainum errors found!"
  echo "Type "(set_color green)"vibranium-healthcheck"(set_color normal)" to repair"
  echo
end
