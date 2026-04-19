# @vibranium
# @description Create simple backups
function backup() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <file|dir> [file|dir...]" >&2
    echo "Error: provide file(s) or directory(ies) to backup" >&2
    return 1
  fi

  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $0 <file|dir> [file|dir...]"
    echo "Creates a .bak copy next to each provided item"
    return 0
  fi

  local item

  for item in "$@"; do
    if [[ ! -e "$item" ]]; then
      echo "Not found: $item" >&2
      return 1
    fi

    if command cp -r -- "$item" "$item.bak"; then
      echo "Copied $item to $item.bak"
    else
      echo "Failed to copy $item" >&2
      return 1
    fi
  done
}
