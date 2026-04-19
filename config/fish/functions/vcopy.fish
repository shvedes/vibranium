# @vibranium
function vcopy --description "Copy text or files"
    function __vcopy_help
        echo "Usage: vcopy <text|file> [more...]"
        echo ""
        echo "Copies text or file paths to Wayland clipboard (wl-copy)."
        echo ""
        echo "Behavior:"
        echo "  - files -> copied as text/uri-list (file://...)"
        echo "  - text  -> copied as text/plain"
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
    end

    if test (count $argv) -eq 0
        __vcopy_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __vcopy_help
        return 0
    end

    set files
    set texts

    for arg in $argv
        if test -f "$arg"
            set files $files $arg
        else
            set texts $texts $arg
        end
    end

    if test (count $files) -gt 0
        for f in $files
            echo "file://"(realpath "$f")
        end | wl-copy --type text/uri-list
    else
        echo -n (string join " " $texts) | wl-copy --type text/plain
    end
end
