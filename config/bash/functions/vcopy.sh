# @vibranium
# @description Copy text or files
function vcopy() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ${FUNCNAME[0]} <text|file> [more...]"
    echo "Copies text or files to clipboard (Wayland wl-copy)"
    echo "Files are copied as file:// URIs, text as plain text"
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    echo "Usage: ${FUNCNAME[0]} <text|file> [more...]" >&2
    echo "Error: provide text or file(s)" >&2
    return 1
  fi

  local -a files=()
  local -a texts=()
  local arg

  for arg in "$@"; do
    if [[ -f "$arg" ]]; then
      files+=("$arg")
    else
      texts+=("$arg")
    fi
  done

  if ((${#files[@]} > 0)); then
    local f
    for f in "${files[@]}"; do
      printf 'file://%s\n' "$(realpath "$f")"
    done | wl-copy --type text/uri-list
  else
    printf '%s' "${texts[*]}" | wl-copy --type text/plain
  fi
}
