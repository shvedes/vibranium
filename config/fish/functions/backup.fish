# @vibranium
function backup --description "Create backups"
    function __backup_help
        echo "Usage: backup <file|dir> [more...]"
        echo ""
        echo "Creates simple backups by copying each item to <name>.bak"
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
        echo ""
        echo "Example:"
        echo "  backup config.json"
        echo "  backup dir1 dir2"
    end

    if test (count $argv) -eq 0
        __backup_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __backup_help
        return 0
    end

    for item in $argv
        if not test -e "$item"
            echo "skip (not found): $item" >&2
            continue
        end

        set dest "$item.bak"

        if test -e "$dest"
            echo "skip (already exists): $dest" >&2
            continue
        end

        command cp -r -- "$item" "$dest"
        echo "Copied $item to $dest"
    end
end
