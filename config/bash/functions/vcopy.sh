# @vibranium
# @description Copy text or files
function vcopy() {
  if [[ $# -eq 0 ]]; then
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
