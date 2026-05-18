# @vibranium
function ccd --description "Create directory and cd into it"
    function __ccd_help
        echo "Usage: ccd <directory>"
        echo ""
        echo "Creates a directory (mkdir -p) and enters it."
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
    end

    if test (count $argv) -eq 0
        __ccd_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __ccd_help
        return 0
    end

    set dir $argv[1]

    mkdir -p -- "$dir"

    if test $status -ne 0
        echo "failed to create directory: $dir" >&2
        return 1
    end

    cd -- "$dir"
end
