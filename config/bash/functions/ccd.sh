# @vibranium
# @description Create directory and cd into it
function ccd() {
  if [[ $# -eq 0 ]]; then
    echo "${FUNCNAME[0]}: you must provide a directory name" >&2
    return 1
  fi

  mkdir -p "$1"
  cd "$1"
}
