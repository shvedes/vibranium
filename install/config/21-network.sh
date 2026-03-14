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

echo -e "${CYAN}[INFO]${RESET} Setting up networking"

InstallPackages iwd impala
UpdateSummary "System / network: installed iwd as wireless backend. Use 'impala' as user TUI frontend"

if pacman -Qq networkmanager &> /dev/null; then
  echo -e "${CYAN}[INFO]${RESET} Removing ${YELLOW}NetworkManager${RESET}"
  sudo pacman -Rnsc --noconfirm networkmanager &> /dev/null
  sudo systemctl -q disable NetworkManager
  UpdateSummary "System / network: replaced NetworkManager with systemd-networkd and iwd"
fi

echo -e "${CYAN}[INFO]${RESET} Configuring network settings"
if [[ -d /etc/systemd/network ]]; then
  files=(/etc/systemd/network/*)

  if (( ${#files[@]} > 0 )); then
    sudo mv /etc/systemd/network \
      /etc/systemd/network.bak
  fi
fi

sudo mkdir -p /etc/systemd/network

echo -e "${CYAN}[INFO]${RESET} Getting ${CYAN}*.network${RESET} reference files"
for file in 20-wwan.network 20-ethernet.network 20-wlan.network; do
  curl -fsSo "/tmp/${file}" "${base_url}/${file}"
  echo -e "${CYAN}[INFO}${RESET} Got ${CYAN}$file${RESET}"
  sudo mv -f "/tmp/${file}" "/etc/systemd/network/${file}"
done

echo -e "${CYAN}[INFO]${RESET} Setting up systemd units"

for unit in ${units[@]}; do
  sudo systemctl -q enable $unit
done

for unit in ${m_units[@]}; do
  sudo systemctl -q disable $unit
  sudo systemctl -q mask $unit
done

if [[ -f /etc/resolv.conf ]]; then
  sudo rm -f /etc/resolv.conf
fi

echo -e "${CYAN}[INFO]${RESET} Symlinking ${CYAN}/etc/resolv.conf${RESET}"
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

UpdateSummary "System / network: configured systemd-networkd with Arch ISO reference profiles"
UpdateSummary "System / network: enabled systemd-resolved as system DNS resolver"
UpdateSummary "System / network: masked systemd-networkd-wait-online to prevent boot delays"
