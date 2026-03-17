# @vibranium
function show-ip --description "Show your public IP"
    if pgrep -f "gpu-screen-recorder|obs|wf-recorder|wl-screenrec" > /dev/null
        read -P "Screen recording/sharing is active. Do you really want to continue? [y/N]: " REPLY
        if test "$REPLY" != "y"
            return 1
        end
    end
    curl -s https://ifconfig.me
end
