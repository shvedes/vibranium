function open --description 'open files with the default application'
    set -l usage 'Usage: open FILE...

Open FILEs and directories with the default application.

Options:
  -h, --help              display this help and exit

Examples:
  open report.pdf
  open ~/Downloads

Note: open is a custom shell function, not a command.'

    if test (count $argv) -eq 0; or test "$argv[1]" = -h; or test "$argv[1]" = --help
        echo $usage >&2
        return 2
    end

    if not command -v xdg-open > /dev/null 2>&1
        echo "open: xdg-open: command not found" >&2
        return 1
    end

    set -l ret 0

    for f in $argv
        if not test -e $f; and not test -L $f
            echo "open: '$f': No such file or directory" >&2
            set ret 1
            continue
        end

        printf "opening %s...\n" $ITL$UND$f$RST
        setsid -f xdg-open $f > /dev/null 2>&1
    end

    return $ret
end
