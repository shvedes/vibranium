
function mkvenv() {
  local usage='Usage: mkvenv NAME

Create a Python virtual environment NAME and activate it.

Options:
  -h, --help              display this help and exit

Examples:
  mkvenv .venv

Note: mkvenv is a custom shell function, not a command.'

  if [[ $1 == -h || $1 == --help ]]; then
    printf '%s\n' "$usage"
    return 0
  fi

  if (($# == 0)); then
    printf '%s\n\n' 'mkvenv: missing NAME' "$usage" >&2
    return 2
  fi

  python -m venv -- "$1" || {
    printf '%s\n' "mkvenv: failed to create venv '$1'" >&2
    return 1
  }

  source "$1/bin/activate"
}
