# @vibranium
function memwatch --description "Monitor memory usage"
    set -l interval 1
    set -l entries 10

    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case -h --help
                echo "Usage: memwatch [OPTIONS]"
                echo ""
                echo "Watch top memory-consuming processes"
                echo ""
                echo "Options:"
                echo "  -i, --interval <sec>    Refresh interval in seconds (default: 1)"
                echo "  -n, --entries  <num>    Number of processes to show  (default: 10)"
                echo "  -h, --help              Show this help message"
                return 0

            case -i --interval
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "memwatch: --interval requires a value" >&2
                    return 1
                end
                set interval $argv[$i]
                if not string match -qr '^[0-9]+(\.[0-9]+)?$' -- $interval
                    echo "memwatch: interval must be a positive number" >&2
                    return 1
                end

            case -n --entries
                set i (math $i + 1)
                if test $i -gt (count $argv)
                    echo "memwatch: --entries requires a value" >&2
                    return 1
                end
                set entries $argv[$i]
                if not string match -qr '^[0-9]+$' -- $entries
                    echo "memwatch: entries must be a positive integer" >&2
                    return 1
                end

            case --
                break
            case '-*'
                echo "memwatch: unknown option $argv[$i]" >&2
                return 1
        end
        set i (math $i + 1)
    end

    # header + column-header + $entries data lines
    set -g __mw_lines (math $entries + 2)
    set -g __mw_started 0
    set -g __mw_exit 0

    function __mw_cleanup --on-signal INT
        set -g __mw_exit 1
        printf "\033[?25h"
        if test "$__mw_started" = 1
            printf "\033[%sA\033[J" $__mw_lines
        end
        functions -e __mw_cleanup
        set -e __mw_lines __mw_started __mw_exit
    end

    printf "\033[?25l"

    while test "$__mw_exit" = 0
        # rss is in KiB — format it as MiB with two decimal places via awk
        set -l output (
      ps -eo pid,comm,rss --sort=-rss \
        | head -n (math $entries + 1) \
        | awk 'NR==1 { printf "%-8s %-20s %10s\n", "PID", "COMMAND", "MiB"; next }
                     { printf "%-8s %-20s %10.2f\n", $1, $2, $3/1024 }'
    )

        if test "$__mw_started" = 0
            echo "Top memory processes (Ctrl+C to exit)"
            for line in $output
                echo $line
            end
            set -g __mw_started 1
        else
            printf "\033[%sA" $__mw_lines
            echo "Top memory processes (Ctrl+C to exit)"
            for line in $output
                echo $line
            end
        end

        sleep $interval
    end

    printf "\033[?25h"
    functions -e __mw_cleanup
    set -e __mw_lines __mw_started __mw_exit
end
