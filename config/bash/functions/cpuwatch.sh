# @vibranium
# @description Monitor CPU usage
function cpuwatch() {
  local interval=1
  local entries=10

  local i=1
  while ((i <= $#)); do
    local arg="${!i}"
    case "$arg" in
    -h | --help)
      echo "Usage: ${FUNCNAME[0]} [OPTIONS]"
      echo ""
      echo "Watch top CPU-consuming processes"
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
        echo "${FUNCNAME[0]}: --interval requires a value" >&2
        return 1
      fi
      interval="${!i}"
      if ! [[ "$interval" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "${FUNCNAME[0]}: interval must be a positive number" >&2
        return 1
      fi
      ;;

    -n | --entries)
      ((i++))
      if ((i > $#)); then
        echo "${FUNCNAME[0]}: --entries requires a value" >&2
        return 1
      fi
      entries="${!i}"
      if ! [[ "$entries" =~ ^[0-9]+$ ]]; then
        echo "${FUNCNAME[0]}: entries must be a positive integer" >&2
        return 1
      fi
      ;;

    --) break ;;
    -*)
      echo "${FUNCNAME[0]}: unknown option $arg" >&2
      return 1
      ;;
    esac
    ((i++))
  done

  local __cw_lines=$((entries + 1))

  while true; do
    local output
    output=$(
      ps -eo pid=,comm=,%cpu= --sort=-%cpu |
        awk -v n="$entries" '
      i < n {
        if ($2 ~ /^\[/) next
        i++
        printf "%-8s %-20s %6.2f\n", $1, $2, $3
      }
    '
    )

    printf "\033[%sA" "$__cw_lines" 2>/dev/null || true

    echo "Top CPU processes (Ctrl+C to exit)"
    echo "$output"

    sleep "$interval" || break
  done
}
