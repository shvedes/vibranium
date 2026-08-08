function bak --description 'fast backup helper'
    set -l usage 'Usage: bak [OPTION]... FILE...

Create backups of FILEs and directories.

Options:
  -p, --prefix=PREFIX     prepend PREFIX to backup names
  -s, --suffix=SUFFIX     append SUFFIX to backup names
  -t, --timestamp         use a Unix timestamp as the suffix
  -H, --hidden            make backup names hidden
  -h, --help              display this help and exit

With no --suffix or --timestamp, ".bak" is appended to the name.
-t wins over -s if both are given (order between them is not
tracked here, unlike the bash/zsh "last one wins" version).

Examples:
  bak file.txt
  bak -p old- file.txt
  bak --suffix=.orig file.txt dir/
  bak --timestamp file.txt
  bak --hidden file.txt

Note: bak is a custom shell function, not a command.'

    argparse 'h/help' 'p/prefix=' 's/suffix=' 't/timestamp' 'H/hidden' -- $argv
    or return 2

    if set -q _flag_help
        echo $usage
        return 0
    end

    if test (count $argv) -eq 0
        echo "bak: missing file operand" >&2
        echo >&2
        echo $usage >&2
        return 2
    end

    set -l prefix ""
    set -l suffix .bak

    if set -q _flag_prefix
        set prefix $_flag_prefix
    end

    if set -q _flag_timestamp
        set suffix "."(date +%s)
    else if set -q _flag_suffix
        set suffix $_flag_suffix
    end

    set -l ret 0

    for src in $argv
        if not test -e $src; and not test -L $src
            echo "bak: '$src': No such file or directory" >&2
            set ret 1
            continue
        end

        set -l name (basename -- $src)
        if set -q _flag_hidden
            set name ".$name"
        end

        cp -a -- $src "$prefix$name$suffix"; or set ret 1
    end

    return $ret
end
