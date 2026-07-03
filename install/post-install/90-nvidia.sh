#!/bin/bash

arch_state_file="/tmp/nvidia-arch"
env_file="$HOME/.config/vibranium/environment"

if [[ ! -f "$arch_state_file" ]]; then
  exit 0
fi

gpu_arch="$(<"$arch_state_file")"


echo -e "\n\n# The lines below were added by the automatic driver configuration\n#\n" >> "$env_file"

if [[ "$gpu_arch" == "turing_plus" ]]; then
  {
    echo "# NVIDIA (Turing+ with GSP firmware)"
    echo "NVD_BACKEND=direct"
    echo "LIBVA_DRIVER_NAME=nvidia"
    echo "__GLX_VENDOR_LIBRARY_NAME=nvidia"
  } >> "$env_file"
elif [[ "$gpu_arch" == "maxwell_pascal_volta" ]]; then
  {
    echo "# NVIDIA (Maxwell/Pascal/Volta without GSP firmware)"
    echo "NVD_BACKEND=egl"
    echo "__GLX_VENDOR_LIBRARY_NAME=nvidia"
  } >> "$env_file"
fi

rm -f "$arch_state_file"
