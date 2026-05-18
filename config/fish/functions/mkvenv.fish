# @vibranium
function mkvenv --description "Create and activate Python virtualenv"
    function __mkvenv_help
        echo "Usage: mkvenv <name>"
        echo ""
        echo "Creates a Python virtual environment and activates it."
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
        echo ""
        echo "Example:"
        echo "  mkvenv .venv"
        echo "  mkvenv env"
    end

    if test (count $argv) -eq 0
        __mkvenv_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __mkvenv_help
        return 0
    end

    set name $argv[1]

    if test -d "$name"
        echo "venv already exists: $name" >&2
        return 1
    end

    python -m venv $name

    if test -f "$name/bin/activate.fish"
        source "$name/bin/activate.fish"
    else
        echo "activation script not found" >&2
        return 1
    end
end
