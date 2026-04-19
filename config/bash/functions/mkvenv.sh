# @vibranium
# @description Create and activate Python virtualenv
function mkvenv() {
  if [[ $# -eq 0 ]]; then
    echo "You must provide a name" >&2
    return 1
  fi

  local venv="$1"

  if ! python -m venv "$venv"; then
    echo "Failed to cretae venv $venv" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$venv/bin/activate"
}
