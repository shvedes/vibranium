#!/bin/bash

if helpers::is_vm; then
  exit 0
fi

# Clear flags from a previous run. Both are set conditionally further down,
# and re-running the installer with a different choice should not leave a
# stale flag from an earlier run lying around for a later phase to trip on.
rm -f /tmp/vibranium-impala-installed /tmp/vibranium-nm.removed

shopt -s nullglob

# Attempt to carry over the active WiFi credentials from NetworkManager to iwd
# before NM is removed. Without this, the system loses network access after the
# daemon switch and the user has to reconnect manually.
#
# Supports WPA2/WPA3-Personal only. 802.1X/enterprise profiles are skipped.
# SSIDs with characters that are invalid in Linux filenames (/ and null) cannot
# be represented as plain iwd profile names; those are also skipped with a
# warning rather than silently failing.
migrate_nm_wifi_to_iwd() {
  # Nothing to migrate if NM is not currently the active daemon.
  if ! command -v nmcli &>/dev/null; then
    return 0
  fi
  if ! systemctl is-active --quiet NetworkManager; then
    return 0
  fi

  local wifi_dev=""
  local ssid=""
  local link_info=""

  # iw dev lists every phy and its interfaces; extract interface names.
  while IFS= read -r dev; do
    link_info=$(iw dev "$dev" link 2>/dev/null)

    # "Not connected." is the literal string iw prints when there is no link.
    if [[ "$link_info" == "Not connected." ]] || [[ -z "$link_info" ]]; then
      continue
    fi

    # Parse the SSID from the link output. The SSID field is everything after
    # the "SSID: " prefix on its line, preserving embedded spaces.
    ssid=$(printf '%s\n' "$link_info" | awk '/^\s+SSID:/{sub(/^\s+SSID: /, ""); print; exit}')

    if [[ -n "$ssid" ]]; then
      wifi_dev="$dev"
      break
    fi
  done < <(iw dev 2>/dev/null | awk '/Interface/{print $2}')

  if [[ -z "$wifi_dev" ]]; then
    helpers::log::warn "No connected WiFi interface found, skipping credential migration"
    return 0
  fi

  helpers::log::info "Active WiFi: interface=${wifi_dev} ssid=${ssid}"

  # Reject SSIDs that cannot be used as-is in a Linux filename. iwd supports
  # an =<hex> filename encoding for such SSIDs but implementing that encoder
  # here is out of scope; warn and skip rather than writing a broken profile.
  if [[ "$ssid" == */* ]] || [[ "$ssid" == *$'\0'* ]]; then
    helpers::log::warn "SSID '${ssid}' contains characters that are not valid in a filename, skipping migration"
    return 0
  fi

  # NM connection files live in /etc/NetworkManager/system-connections/ and are
  # owned root:root 600, so all reads below require sudo.
  #
  # Search for the profile whose [wifi] section declares the active SSID.
  # grep -r returns all matches; we take the first. On a typical desktop there
  # is exactly one profile per SSID.
  local nm_conn_file
  nm_conn_file=$(
    sudo grep -rl "^ssid=${ssid}$" /etc/NetworkManager/system-connections/ 2>/dev/null |
      head -n1
  )

  if [[ -z "$nm_conn_file" ]]; then
    helpers::log::warn "No NetworkManager profile found for SSID '${ssid}', skipping migration"
    return 0
  fi

  helpers::log::info "Found NetworkManager profile: ${nm_conn_file}"

  # Extract the psk= value. The value may itself contain '=' (e.g. a base64
  # passphrase), so strip only the leading "psk=" prefix via sub() rather than
  # splitting on '=' with awk's -F flag.
  local psk
  psk=$(
    sudo awk '
      /^\[wifi-security\]/ { in_sec = 1; next }
      /^\[/                { in_sec = 0 }
      in_sec && /^psk=/    { sub(/^psk=/, ""); print; exit }
    ' "$nm_conn_file"
  )

  if [[ -z "$psk" ]]; then
    helpers::log::warn "No PSK field in the NetworkManager profile for '${ssid}' (open network?), skipping migration"
    return 0
  fi

  # NM can store the credential in two forms:
  #   - A 64-character lowercase hex string: the raw 256-bit pre-shared key,
  #     derived by PBKDF2 from the passphrase. iwd calls this PreSharedKey=.
  #   - Anything else: the human-readable WPA passphrase (8-63 ASCII chars or
  #     a valid UTF-8 sequence). iwd calls this Passphrase=.
  local iwd_key_line
  if [[ "$psk" =~ ^[0-9a-fA-F]{64}$ ]]; then
    iwd_key_line="PreSharedKey=${psk}"
  else
    iwd_key_line="Passphrase=${psk}"
  fi

  # Write the iwd network profile.
  # Format: plain INI file at /var/lib/iwd/<SSID>.psk
  # Permissions must be 600; iwd refuses to load world-readable profiles.
  local iwd_profile="/var/lib/iwd/${ssid}.psk"

  printf '[Security]\n%s\n' "$iwd_key_line" | helpers::write_file "$iwd_profile"
  sudo chmod 600 "$iwd_profile"

  helpers::log::info "Wrote iwd profile for '${ssid}' -> ${iwd_profile}"
}

# Switch the active network stack to NetworkManager. Also handles the
# re-run case where an earlier Vibranium install had already switched the
# machine to systemd-networkd + iwd, so this is safe to use as the
# steady-state choice even on a non-fresh system.
use_network_manager() {
  helpers::log::info "Setting up NetworkManager"

  if ! pacman -Qq networkmanager &>/dev/null; then
    helpers::install_pkg networkmanager
  fi

  if systemctl is-enabled --quiet iwd 2>/dev/null || systemctl is-enabled --quiet systemd-networkd 2>/dev/null; then
    helpers::log::info "Reverting a previous systemd-networkd / iwd setup"
    sudo systemctl -q disable --now iwd systemd-networkd systemd-resolved 2>/dev/null
    sudo systemctl -q unmask systemd-networkd-wait-online 2>/dev/null
    # NetworkManager manages /etc/resolv.conf itself once active; drop the
    # stub-resolv.conf symlink systemd-resolved left behind so it does not
    # linger and confuse the next thing that reads it.
    helpers::remove /etc/resolv.conf
  fi

  sudo systemctl -q enable --now NetworkManager
}

# Switch the active network stack to systemd-networkd + iwd, migrating
# active NetworkManager WiFi credentials first so the machine does not
# lose network access after the daemon switch.
use_networkd_and_iwd() {
  local units=(
    iwd
    systemd-resolved
    systemd-networkd
    systemd-timesyncd
  )
  local masked_units=(
    systemd-networkd-wait-online
  )

  # Use archiso's default network settings as reference.
  # There's no clear reason for this decision. I just like being dumb.
  local base_url="https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/configs/releng/airootfs/etc/systemd/network"

  helpers::log::info "Setting up systemd-networkd and iwd"
  helpers::install_pkg iw iwd

  if helpers::has_wifi_adapter; then
    helpers::install_pkg impala
    : >/tmp/vibranium-impala-installed
  else
    helpers::log::info "No wireless adapter detected, skipping impala (iwd's TUI frontend)"
  fi

  if pacman -Qq networkmanager &>/dev/null; then
    helpers::log::info "Detected NetworkManager, migrating active WiFi credentials"

    # Run migration before NM is stopped so nmcli and the connection files are
    # still accessible. The function is safe to call even if there is nothing
    # to migrate; it exits early with a warning in every failure path.
    migrate_nm_wifi_to_iwd

    helpers::log::info "Removing NetworkManager"
    sudo pacman -Rnsc --noconfirm networkmanager &>/dev/null
    sudo systemctl -q disable NetworkManager
    : >/tmp/vibranium-nm.removed
  fi

  helpers::log::info "Configuring network settings"
  sudo mkdir -p /etc/systemd/network

  helpers::log::info "Getting *.network reference files"
  for file in 20-wwan.network 20-ethernet.network 20-wlan.network; do
    curl -4 -fsSo "/tmp/${file}" "${base_url}/${file}"
    helpers::copy "/tmp/${file}" "/etc/systemd/network/${file}"
    helpers::log::info "Got ${file}"
    rm -f "/tmp/${file}"
  done

  helpers::log::info "Setting up systemd units"

  for unit in "${units[@]}"; do
    sudo systemctl -q enable "$unit"
  done

  for unit in "${masked_units[@]}"; do
    sudo systemctl -q disable "$unit"
    sudo systemctl -q mask "$unit"
  done

  helpers::log::info "Symlinking /etc/resolv.conf"
  helpers::symlink /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  sudo systemctl -q restart systemd-resolved
}

# systemd-networkd already up and running (earlier install or manual setup),
# no migration needed, don't ask.
if systemctl -q is-active systemd-networkd; then
  helpers::log::info "systemd-networkd is already active, skipping prompt"
elif term::ask_yes_no N "Would you like to use ${C}systemd-networkd${RS} instead of ${C}NetworkManager${RS}?"; then
  helpers::log::info "Setting up networking"
  use_networkd_and_iwd
else
  use_network_manager
fi
