
function open() {
  local usage='Usage: open FILE...

Open FILEs and directories with the default application.

Options:
  -h, --help              display this help and exit

Examples:
  open report.pdf
  open ~/Downloads

Note: open is a custom shell function, not a command.'

  if (($# == 0)) || [[ $1 == -h || $1 == --help ]]; then
    printf '%s\n' "$usage" >&2
    return 2
  fi

  if ! command -v xdg-open > /dev/null 2>&1; then
    printf '%s\n' "open: xdg-open: command not found" >&2
    return 1
  fi

  local f ret=0

  for f; do
    if [[ ! -e $f && ! -L $f ]]; then
      printf '%s\n' "open: '$f': No such file or directory" >&2
      ret=1
      continue
    fi

    printf "opening %s...\n" "${ITL}${UND}$f${RST}"
    setsid -f xdg-open "$f" > /dev/null 2>&1
  done

  return $ret
}
