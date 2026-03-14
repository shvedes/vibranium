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

base_url="https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/configs/releng/airootfs/etc/systemd/network"

echo -e "${CYAN}[INFO]${RESET} Setting up networking"

InstallPackages iwd impala

if pacman -Qq networkmanager &> /dev/null; then
  echo -e "${CYAN}[INFO]${RESET} Removing ${YELLOW}NetworkManager${RESET}"
  sudo pacman -Rnsc --noconfirm networkmanager &> /dev/null
  sudo systemctl -q disable NetworkManager
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

for file in 20-wwan.network 20-ethernet.network 20-wlan.network; do
  curl -fsSo "/tmp/${file}" "${base_url}/${file}"
  sudo mv -f "/tmp/${file}" "/etc/systemd/network/${file}"
done

for unit in ${units[@]}; do
  echo -e "${CYAN}[INFO]${RESET} Enabling ${YELLOW}${unit}.service${RESET}"
  sudo systemctl -q enable $unit
done

for unit in ${m_units[@]}; do
  echo -e "${CYAN}[INFO]${RESET} Masking ${YELLOW}${unit}.service${RESET}"
  sudo systemctl -q disable $unit
  sudo systemctl -q mask $unit
done

