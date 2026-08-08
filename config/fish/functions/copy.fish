function copy --description 'copy files to clipboard as file:// URIs'
    set -l usage 'Usage: copy FILE...

Copy FILEs to the clipboard as file:// URIs.

Options:
  -h, --help              display this help and exit

Examples:
  copy report.pdf image.png

Note: copy is a custom shell function, not a command.'

    if test (count $argv) -eq 0; or test "$argv[1]" = -h; or test "$argv[1]" = --help
        echo $usage >&2
        return 2
    end

    set -l ret 0

    for f in $argv
        if not test -f $f
            echo "copy: '$f': Not a file" >&2
            set ret 1
        end
    end

    if test $ret -ne 0
        return $ret
    end

    for f in $argv
        printf 'file://%s\n' (realpath -- $f)
    end | wl-copy --type text/uri-list
end
