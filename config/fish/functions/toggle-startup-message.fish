function toggle-startup-message --description 'toggle the fish startup message'
    set -l usage 'Usage: toggle-startup-message

Toggle the startup message on or off.

Options:
  -h, --help              display this help and exit'

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        echo $usage
        return 0
    end

    if test -f "$FISH_CONFIG_DIR/.silent"
        rm -f -- "$FISH_CONFIG_DIR/.silent"
        echo "Startup message "$GRN"enabled"$RST
    else
        touch "$FISH_CONFIG_DIR/.silent"
        echo "Startup message "$RED"disabled"$RST
    end
end
