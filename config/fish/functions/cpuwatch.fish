# @vibranium
function cpuwatch --description "CPU usage monitoring"
  set -l interval 1
  set -l entries  10

  set -l i 1
  while test $i -le (count $argv)
    switch $argv[$i]
      case -h --help
        echo "Usage: cpuwatch [OPTIONS]"
        echo ""
        echo "Watch top CPU-consuming processes"
        echo ""
        echo "Options:"
        echo "  -i, --interval <sec>    Refresh interval in seconds (default: 1)"
        echo "  -n, --entries  <num>    Number of processes to show  (default: 10)"
        echo "  -h, --help              Show this help message"
        return 0

      case -i --interval
        set i (math $i + 1)
        if test $i -gt (count $argv)
          echo "cpuwatch: --interval requires a value" >&2; return 1
        end
        set interval $argv[$i]
        if not string match -qr '^[0-9]+(\.[0-9]+)?$' -- $interval
          echo "cpuwatch: interval must be a positive number" >&2; return 1
        end

      case -n --entries
        set i (math $i + 1)
        if test $i -gt (count $argv)
          echo "cpuwatch: --entries requires a value" >&2; return 1
        end
        set entries $argv[$i]
        if not string match -qr '^[0-9]+$' -- $entries
          echo "cpuwatch: entries must be a positive integer" >&2; return 1
        end

      case --
        break
      case '-*'
        echo "cpuwatch: unknown option $argv[$i]" >&2; return 1
    end
    set i (math $i + 1)
  end

  set -g __cw_lines   (math $entries + 1)
  set -g __cw_started 0
  set -g __cw_exit    0

  function __cw_cleanup --on-signal INT
    set -g __cw_exit 1
    printf "\033[?25h"
    if test "$__cw_started" = "1"
      printf "\033[%sA\033[J" $__cw_lines
    end
    functions -e __cw_cleanup
    set -e __cw_lines __cw_started __cw_exit
  end

  printf "\033[?25l"

  while test "$__cw_exit" = "0"
    set -l output (ps -eo pid,comm,%cpu --sort=-%cpu | head -n $entries)

    if test "$__cw_started" = "0"
      echo "Top CPU processes (Ctrl+C to exit)"
      for line in $output
        echo $line
      end
      set -g __cw_started 1
    else
      printf "\033[%sA" $__cw_lines
      echo "Top CPU processes (Ctrl+C to exit)"
      for line in $output
        echo $line
      end
    end

    sleep $interval
  end

  printf "\033[?25h"
  functions -e __cw_cleanup
  set -e __cw_lines __cw_started __cw_exit
end
