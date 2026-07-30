# @vibranium
# @description Open files or URLs
function open() {
  if ((${#@} == 0)); then
    echo "error: ${FUNCNAME[0]} expects a FILE or a URL"
    return 1
  fi

  setsid -f xdg-open "$@" &> /dev/null
}
