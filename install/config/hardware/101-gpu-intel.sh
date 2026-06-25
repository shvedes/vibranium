#!/usr/bin/env bash

if ! vb-hw-gpu intel; then
  exit 0
fi

helpers::log::info "Installing Intel GPU drivers"

packages=(
  "mesa"
  "nvtop"
  "lib32-mesa"
  "vulkan-intel"
  "lib32-vulkan-intel"
)

# Fetch the specific hardware generation string
# for microarchitecture mapping
VGA_STR="$(lspci -nn | grep -i "8086:")"

case "$VGA_STR" in
  # Broadwell (2014) and newer
  *Broadwell* | *Skylake* | *"Kaby Lake"* | *"Coffee Lake"* | *"Comet Lake"* | *"Ice Lake"* | *"Tiger Lake"* | *"Alder Lake"* | *"Raptor Lake"* | *Arc*)
    packages+=("intel-media-driver")
    ;;

  # GMA 4500 (2008) up to pre-Broadwell
  *Penryn* | *Nehalem* | *Westmere* | *"Sandy Bridge"* | *"Ivy Bridge"* | *Haswell*)
    packages+=("libva-intel-driver")
    ;;
esac

case "$VGA_STR" in
  *"Tiger Lake"* | *"Alder Lake"* | *"Raptor Lake"*)
    packages+=("vpl-gpu-rt")
    ;;

  *)
    packages+=("intel-media-sdk")
    ;;
esac

helpers::install_pkg "${packages[@]}"
