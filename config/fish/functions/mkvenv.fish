function mkvenv --description 'create and activate a Python venv'
    set -l usage 'Usage: mkvenv NAME

Create a Python virtual environment NAME and activate it.

Options:
  -h, --help              display this help and exit

Examples:
  mkvenv .venv

Note: mkvenv is a custom shell function, not a command.'

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        echo $usage
        return 0
    end

    if test (count $argv) -eq 0
        echo "mkvenv: missing NAME" >&2
        echo >&2
        echo $usage >&2
        return 2
    end

    python -m venv -- $argv[1]
    or begin
        echo "mkvenv: failed to create venv '$argv[1]'" >&2
        return 1
    end

    # fish needs the .fish activation script, not the bash/zsh one.
    source $argv[1]/bin/activate.fish
end
