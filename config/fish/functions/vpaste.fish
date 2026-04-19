# @vibranium
function vpaste --description "Paste into command line"
    function __vpaste_help
        echo "Usage: vpaste"
        echo ""
        echo "Pastes clipboard content (wl-paste) into the current command line."
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
    end

    if test (count $argv) -gt 0
        if test "$argv[1]" = -h; or test "$argv[1]" = --help
            __vpaste_help
            return 0
        end
    end

    set clip (wl-paste)

    if test -z "$clip"
        return 1
    end

    commandline -i -- "$clip"
end
