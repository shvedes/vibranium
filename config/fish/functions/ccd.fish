function ccd --description 'mkdir -p and cd into it'
    set -l usage 'Usage: ccd DIRECTORY

Create DIRECTORY (with parents) and cd into it.

Options:
  -h, --help              display this help and exit

Examples:
  ccd src/components/header

Note: ccd is a custom shell function, not a command.'

    if test (count $argv) -eq 0; or test "$argv[1]" = -h; or test "$argv[1]" = --help
        echo $usage >&2
        return 2
    end

    mkdir -p -- $argv[1]; or return 1
    cd -- $argv[1]; or return 1
end
