
function copy() {
  local usage='Usage: copy FILE...

Copy FILEs to the clipboard as file:// URIs.

Options:
  -h, --help              display this help and exit

Examples:
  copy report.pdf image.png

Note: copy is a custom shell function, not a command.'

  if (($# == 0)) || [[ $1 == -h || $1 == --help ]]; then
    printf '%s\n' "$usage" >&2
    return 2
  fi

  local f status=0

  for f; do
    if [[ ! -f $f ]]; then
      printf '%s\n' "copy: '$f': Not a file" >&2
      status=1
    fi
  done

  (($status)) && return $status

  for f; do
    printf 'file://%s\n' "$(realpath -- "$f")"
  done | wl-copy --type text/uri-list
}
