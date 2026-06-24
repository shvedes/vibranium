#!/usr/bin/env bash

helpers::is_vm() {
  [[ "$CHASSIS_TYPE" == vm ]]
}

# True if the kernel has registered at least one wireless network
# interface. Checked at the sysfs level on purpose, so it works before
# iw/iwd/NetworkManager are installed and regardless of which one ends up
# managing the connection.
#
# /sys/class/net/<iface>/wireless   - present on older drivers (mac80211)
# /sys/class/net/<iface>/phy80211   - symlink present on modern cfg80211 drivers
helpers::has_wifi_adapter() {
  local iface
  for iface in /sys/class/net/*/; do
    [[ -d "${iface}wireless" || -d "${iface}phy80211" ]] && return 0
  done
  return 1
}
