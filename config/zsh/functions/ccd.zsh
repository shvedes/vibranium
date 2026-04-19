# @vibranium
# @description Create directory and cd into it
function ccd() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: ${funcstack[1]} <directory>" >&2
    echo "${funcstack[1]}: you must provide a directory name" >&2
    return 1
  fi

  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: ${funcstack[1]} <directory>"
    echo "Creates directory if it doesn't exist and changes into it"
    return 0
  fi

  mkdir -p "$1" || return 1
  cd "$1" || return 1
}
