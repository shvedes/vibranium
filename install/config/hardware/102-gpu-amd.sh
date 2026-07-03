#!/bin/bash

# Early exit if no AMD GPU is found
if ! vb-hw-gpu amd; then
  exit 0
fi

helpers::log::info "Installing AMD GPU drivers"

packages=(
  "mesa"
  "nvtop"
  "lib32-mesa"
  "rocm-smi-lib" # Needed for btop's gpu usage graph
  "vulkan-radeon"
  "libvdpau-va-gl"
  "lib32-vulkan-radeon"
)

helpers::install_pkg "${packages[@]}"
