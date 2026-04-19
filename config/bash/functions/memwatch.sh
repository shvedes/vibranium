function memwatch() {
  local interval=1
  local entries=10

  local i=1
  while ((i <= $#)); do
    local arg="${!i}"
    case "$arg" in
    -h | --help)
      echo "Usage: memwatch [OPTIONS]"
      echo ""
      echo "Watch top memory-consuming processes"
      echo ""
      echo "Options:"
      echo "  -i, --interval <sec>    Refresh interval in seconds (default: 1)"
      echo "  -n, --entries  <num>    Number of processes to show  (default: 10)"
      echo "  -h, --help              Show this help message"
      return 0
      ;;

    -i | --interval)
      ((i++))
      if ((i > $#)); then
        echo "memwatch: --interval requires a value" >&2
        return 1
      fi
      interval="${!i}"
      if ! [[ "$interval" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "memwatch: interval must be a positive number" >&2
        return 1
      fi
      ;;

    -n | --entries)
      ((i++))
      if ((i > $#)); then
        echo "memwatch: --entries requires a value" >&2
        return 1
      fi
      entries="${!i}"
      if ! [[ "$entries" =~ ^[0-9]+$ ]]; then
        echo "memwatch: entries must be a positive integer" >&2
        return 1
      fi
      ;;

    --)
      break
      ;;

    -*)
      echo "memwatch: unknown option $arg" >&2
      return 1
      ;;
    esac
    ((i++))
  done

  local __mw_lines=$((entries + 2))
  local __mw_started=0
  local __mw_exit=0

  local __mw_old_trap
  __mw_old_trap=$(trap -p INT)

  # Only set the exit flag here. Doing any terminal work inside the handler
  # and then restoring the default INT trap causes Bash to re-deliver SIGINT
  # on handler return, which kills the process before escape sequences are
  # flushed — leaving the cursor hidden.
  __mw_cleanup() {
    __mw_exit=1
  }

  trap __mw_cleanup INT

  printf "\033[?25l"

  while [[ "$__mw_exit" == "0" ]]; do
    local output
    output=$(
      ps -eo pid,comm,rss --sort=-rss |
        head -n $((entries + 1)) |
        awk 'NR==1 { printf "%-8s %-20s %10s\n",  "PID", "COMMAND", "MiB"; next }
                     { printf "%-8s %-20s %10.2f\n", $1,   $2,        $3/1024 }'
    )

    if [[ "$__mw_started" == "0" ]]; then
      echo "Top memory processes (Ctrl+C to exit)"
      while IFS= read -r line; do
        echo "$line"
      done <<<"$output"
      __mw_started=1
    else
      printf "\033[%sA" "$__mw_lines"
      echo "Top memory processes (Ctrl+C to exit)"
      while IFS= read -r line; do
        echo "$line"
      done <<<"$output"
    fi

    sleep "$interval"
  done

  # Unified exit path: runs after both Ctrl+C and any future clean break.
  # The cursor is guaranteed to be shown here because we never kill the
  # process from inside the trap handler.
  printf "\033[?25h"
  if [[ "$__mw_started" == "1" ]]; then
    printf "\033[%sA\033[J" "$__mw_lines"
  fi
  if [[ -n "$__mw_old_trap" ]]; then
    eval "$__mw_old_trap"
  else
    trap - INT
  fi
  unset -f __mw_cleanup
}
