#!/bin/bash

if ! vb-hw-gpu nvidia; then
  exit 0
fi

# Match the installed kernel variant so dkms gets headers for the exact kernel that is running.
kernel_pkg="$(pacman -Qqs '^linux(-zen|-lts|-hardened)?$' | head -1)"

if [[ -z "$kernel_pkg" ]]; then
  helpers::log::error "Could not determine installed kernel package, aborting NVIDIA setup" >&2
  exit 1
fi

kernel_headers="${kernel_pkg}-headers"

gpu_arch=""
packages=("nvidia-settings")

# Check for newer Turing+ architectures using the GSR capabilities flag
if vb-hw-gpu -g nvidia; then
  packages+=(nvidia-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver)
  gpu_arch="turing_plus"
else
  packages+=(nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils)
  gpu_arch="maxwell_pascal_volta"
fi

if [[ -z "$gpu_arch" ]]; then
  helpers::log::warn "No compatible driver for your NVIDIA GPU"
  helpers::log::warn "See: ${C}https://wiki.archlinux.org/title/NVIDIA${RS}"
  exit 0
fi

helpers::install_pkg "$kernel_headers" "${packages[@]}"

helpers::write_file /etc/modprobe.d/nvidia.conf <<EOF
options nvidia_drm modeset=1
EOF

helpers::write_file /etc/mkinitcpio.conf.d/nvidia.conf <<EOF
MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
EOF

helpers::log::info "Regenerating mkinitcpio"
sudo mkinitcpio -P &>/dev/null

printf '%s' "$gpu_arch" >/tmp/nvidia-arch
helpers::log::info "NVIDIA driver installed for ${C}${gpu_arch}${RS}"
