function fish_greeting
    if test -f "$$__fish_config_dir/.silent"
        return 0
    end

    echo "Edit config in: "$YEL"~/.config/fish"$RST
    echo "Hide this message: "$GRN"toggle-startup-message"$RST
    echo "Fish documentation: "$GRN"man "$YEL"fish"$RST
    echo "Registered aliases: "$GRN"alias"$RST

    if functions -q fisher
        echo "Plugin manager help: "$GRN"fisher "$YEL"--help"$RST
    end

    echo "Abbreviation list: "$GRN"abbr "$YEL"--list"$RST
    echo

    if not test -c /dev/tty; or test "$TERM" != linux
        if test -n "$VIBRANIUM_STATE"; and test -f "$VIBRANIUM_STATE/update.available"
            echo "Vibranium update available! Update in the settings."
            echo
        end
    end

    if test -n "$VIBRANIUM"; and test -f "$VIBRANIUM_STATE/errors_found"
        echo "Vibranium "$RED"errors"$RST" found! Type "$GRN"vibranium-healthcheck"$RST" to repair."
        echo
    end
end
