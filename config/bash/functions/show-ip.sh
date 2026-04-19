# @vibranium
# @description Show public IP address
function show-ip() {
  local _ip

  if pgrep -f "gpu-screen-recorder|obs|wf-recorder|wl-screenrec" >/dev/null; then
    local reply
    read -p "Screen recording/sharing is active. Do you really want to continue? [y/N]: " reply
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
