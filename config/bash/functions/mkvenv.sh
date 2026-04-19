# @vibranium
# @description Create and activate Python virtualenv
function mkvenv() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ${FUNCNAME[0]} <name>"
    echo "Creates a Python virtual environment and activates it"
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    echo "Usage: ${FUNCNAME[0]} <name>" >&2
    echo "You must provide a name" >&2
    return 1
  fi

  local venv="$1"

  if ! python -m venv "$venv"; then
    echo "Failed to create venv $venv" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$venv/bin/activate"
}
