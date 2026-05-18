function memwatch() {
  local interval=1
  local entries=10

  local i=1
  while ((i <= $#)); do
    local arg="${!i}"
    case "$arg" in
    -h | --help)
      echo "Usage: ${FUNCNAME[0]} [OPTIONS]"
      echo "Watch top memory-consuming processes"
      echo "  -i, --interval <sec>"
      echo "  -n, --entries  <num>"
      return 0
      ;;

    -i | --interval)
      ((i++))
      interval="${!i}"
      ;;

    -n | --entries)
      ((i++))
      entries="${!i}"
      ;;

    --) break ;;
    -*)
      echo "${FUNCNAME[0]}: unknown option $arg" >&2
      return 1
      ;;
    esac
    ((i++))
  done

  local __mw_lines=$((entries + 2))

  while true; do
    local output
    output=$(
      ps -eo pid=,comm=,rss= --sort=-rss |
        awk -v n="$entries" '
      NR==1 {
        printf "%-8s %-20s %10s\n","PID","COMMAND","MiB"
        next
      }
      $2 ~ /^\[/ { next }   # skip kernel threads like [kworker/...]
      i++ < n {
        printf "%-8s %-20s %10.2f\n", $1, $2, $3/1024
      }
    '
    )

    printf "\033[%sA" "$__mw_lines" 2>/dev/null || true

    echo "Top memory processes (Ctrl+C to exit)"
    echo "$output"

    sleep "$interval" || break
  done
}
