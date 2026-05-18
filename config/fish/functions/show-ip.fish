# @vibranium
function show-ip --description "Show public IP address"
    function __show_ip_help
        echo "Usage: show-ip"
        echo ""
        echo "Fetches your public IP address via ifconfig.me"
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
    end

    if test (count $argv) -gt 0
        if test "$argv[1]" = -h; or test "$argv[1]" = --help
            __show_ip_help
            return 0
        end
    end

    if pgrep -f "gpu-screen-recorder|obs|wf-recorder|wl-screenrec" >/dev/null
        read -P "Screen recording/sharing is active. Do you really want to continue? [y/N]: " REPLY
        if test "$REPLY" != y
            return 1
        end
    end

    curl -s https://ifconfig.me
end
