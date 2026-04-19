# @vibranium
# @description Show public IP address
function show-ip() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ${FUNCNAME[0]}"
    echo "Shows your public IP address using ifconfig.me"
    echo "Performs a quick connectivity check before request"
    return 0
  fi

  local _ip

  if pgrep -f "gpu-screen-recorder|obs|wf-recorder|wl-screenrec" >/dev/null; then
    local reply
    read -r -p "Screen recording/sharing is active. Do you really want to continue? [y/N]: " reply
    if [[ ! "$reply" =~ ^([Yy]([Ee][Ss])?)$ ]]; then
      return 1
    fi
  fi

  # Quick internet check (TCP connect to 1.1.1.1:53)
  if ! timeout 2 bash -c "</dev/tcp/1.1.1.1/53" 2>/dev/null; then
    echo "No internet connection" >&2
    return 1
  fi

  if ! _ip="$(curl -fsS --max-time 5 https://ifconfig.me)"; then
    echo "Failed to retrieve IP" >&2
    return 1
  fi

  echo "$_ip"
}
