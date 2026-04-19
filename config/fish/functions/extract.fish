# @vibranium
function extract --description "Extract archives"
    function __extract_help
        echo "Usage: extract <file>"
        echo ""
        echo "Supported formats:"
        echo "  .tar, .tar.gz, .tgz  -> tar"
        echo "  .zip                 -> unzip or 7z"
        echo "  .7z                  -> 7z"
        echo "  .rar                 -> unrar or 7z"
        echo ""
        echo "Options:"
        echo "  -h, --help          Show this help"
    end

    if test (count $argv) -eq 0
        __extract_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __extract_help
        return 0
    end

    set file $argv[1]

    if not test -f "$file"
        echo "Error: file not found: $file" >&2
        return 1
    end

    switch $file
        case "*.tar*" "*.tgz"
            tar -xf $file
        case "*.zip"
            if command -sq unzip
                unzip $file
            else if command -sq 7z
                7z x $file
            else
                echo "No unzip or 7z available" >&2
                return 1
            end
        case "*.7z"
            if command -sq 7z
                7z x $file
            else
                echo "7z not installed" >&2
                return 1
            end
        case "*.rar"
            if command -sq unrar
                unrar x $file
            else if command -sq 7z
                7z x $file
            else
                echo "No unrar or 7z available" >&2
                return 1
            end
        case "*"
            if command -sq 7z
                7z x $file
            else
                echo "Unknown format and no 7z fallback: $file" >&2
                return 1
            end
    end
end
