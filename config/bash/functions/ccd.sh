
# ccd: create a directory and cd into it. Builtins only. No subshells.

function ccd() {
  local usage='Usage: ccd DIRECTORY

Create DIRECTORY (with parents) and cd into it.

Options:
  -h, --help              display this help and exit

Examples:
  ccd src/components/header

Note: ccd is a custom shell function, not a command.'

  if (($# == 0)) || [[ $1 == -h || $1 == --help ]]; then
    printf '%s\n' "$usage" >&2
    return 2
  fi

  mkdir -p -- "$1" || return 1
  cd -- "$1" || return 1
}
