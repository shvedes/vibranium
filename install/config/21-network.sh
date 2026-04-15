#!/usr/bin/env bash

if [[ "$CHASSIS_TYPE" == vm ]]; then
  exit 0
fi

shopt -s nullglob

units=(
  iwd
  systemd-resolved
  systemd-networkd
  systemd-timesyncd
)
m_units=(
  systemd-networkd-wait-online
)

# Use archiso's default network settings as reference.
# There's no clear reason for this decision. I just like being dumb.
base_url="https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/configs/releng/airootfs/etc/systemd/network"

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
    _log_warn "No associated WiFi interface found; skipping migration"
    return 0
  fi

  _log_info "Active WiFi: interface=${wifi_dev} ssid=${ssid}"

  # Reject SSIDs that cannot be used as-is in a Linux filename. iwd supports
  # an =<hex> filename encoding for such SSIDs but implementing that encoder
  # here is out of scope; warn and skip rather than writing a broken profile.
  if [[ "$ssid" == */* ]] || [[ "$ssid" == *$'\0'* ]]; then
    _log_warn "SSID '${ssid}' contains characters invalid in a filename; skipping migration"
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
    _log_warn "No NM connection profile found for SSID '${ssid}'; skipping migration"
    return 0
  fi

  _log_info "Found NM profile: ${nm_conn_file}"

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
    _log_warn "No PSK field in NM profile for '${ssid}' (open network?); skipping migration"
    return 0
  fi

  # NM can store the credential in two forms:
  #   - A 64-character lowercase hex string: the raw 256-bit pre-shared key,
  #     derived by PBKDF2 from the passphrase. iwd calls this PreSharedKey=.
  #   - Anything else: the human-readable WPA passphrase (8–63 ASCII chars or
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
  sudo mkdir -p /var/lib/iwd

  local iwd_profile="/var/lib/iwd/${ssid}.psk"

  # Warn rather than silently clobber a profile that was written by a previous
  # run or by the user manually.
  if sudo test -f "$iwd_profile"; then
    _log_warn "iwd profile already exists at '${iwd_profile}'; overwriting"
  fi

  printf '[Security]\n%s\n' "$iwd_key_line" | sudo tee "$iwd_profile" >/dev/null
  sudo chmod 600 "$iwd_profile"

  _log_info "Wrote iwd profile for '${ssid}' -> ${iwd_profile}"
  UpdateSummary "System / network: migrated WiFi credentials for '${ssid}' from NetworkManager to iwd"
}

_log_info "Setting up networking"

InstallPackages iw iwd impala
UpdateSummary "System / network: installed iwd as wireless backend. Use 'impala' as user TUI frontend"

if pacman -Qq networkmanager &>/dev/null; then
  _log_info "Detected NetworkManager; migrating active WiFi credentials"

  # Run migration before NM is stopped so nmcli and the connection files are
  # still accessible. The function is safe to call even if there is nothing to
  # migrate; it exits early with a warning in every failure path.
  migrate_nm_wifi_to_iwd

  _log_info "Removing NetworkManager"
  sudo pacman -Rnsc --noconfirm networkmanager &>/dev/null
  sudo systemctl -q disable NetworkManager
  touch /tmp/vibranium-nm.removed
  UpdateSummary "System / network: replaced NetworkManager with systemd-networkd and iwd"
fi

_log_info "Configuring network settings"
if [[ -d /etc/systemd/network ]]; then
  files=(/etc/systemd/network/*)

  if ((${#files[@]} > 0)); then
    sudo mv /etc/systemd/network \
      /etc/systemd/network.bak
  fi
fi

sudo mkdir -p /etc/systemd/network

_log_info "Getting *.network reference files"
for file in 20-wwan.network 20-ethernet.network 20-wlan.network; do
  curl -fsSo "/tmp/${file}" "${base_url}/${file}"
  _log_info "Got ${file}"
  sudo mv -f "/tmp/${file}" "/etc/systemd/network/${file}"
done

_log_info "Setting up systemd units"

for unit in "${units[@]}"; do
  sudo systemctl -q enable "$unit"
done

for unit in "${m_units[@]}"; do
  sudo systemctl -q disable "$unit"
  sudo systemctl -q mask "$unit"
done

if [[ -f /etc/resolv.conf ]]; then
  sudo rm -f /etc/resolv.conf
fi

_log_info "Symlinking /etc/resolv.conf"
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sudo systemctl -q restart systemd-resolved

UpdateSummary "System / network: configured systemd-networkd with Arch ISO reference profiles"
UpdateSummary "System / network: enabled systemd-resolved as system DNS resolver"
UpdateSummary "System / network: masked systemd-networkd-wait-online to prevent boot delays"
