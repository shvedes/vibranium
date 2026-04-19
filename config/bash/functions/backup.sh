# @vibranium
# @description Create simple backups
function backup() {
  if [[ $# -eq 0 ]]; then
    echo "Error: provide file(s) or directory(ies) to backup" >&2
    return 1
  fi

  local item

  for item in "$@"; do
    if [[ ! -e "$item" ]]; then
      echo "Not found: $item" >&2
      return 1
    fi

    if cp -r -- "$item" "$item.bak"; then
      echo "Copied $item to $item.bak"
    else
      echo "Failed to copy $item" >&2
      return 1
    fi
  done
}
