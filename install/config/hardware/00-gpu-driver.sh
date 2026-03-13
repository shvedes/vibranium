#!/usr/bin/env bash

NVIDIA_SETUP_NEEDED=false
PACKAGES=()

VGA_STR="$(lspci | grep -iE "vga|3d")"

case "$VGA_STR" in
  *Nvidia*)
    _log_info "Installing NVIDIA GPU drivers"
    NVIDIA_SETUP_NEEDED=true
    PACKAGES+=(
      "nvtop"
      "egl-wayland"
      "nvidia-dkms"
      "nvidia-utils"
      "linux-headers"
      "nvidia-settings"
      "lib32-nvidia-utils"
      "libva-nvidia-driver"
    )
    ;;

  *Radeon* | *ATI*)
    _log_info "Installing AMD GPU drivers"
    PACKAGES+=(
      "mesa"
      "nvtop"
      "lib32-mesa"
      "rocm-smi-lib" # Needed for btop's gpu usage graph
      "vulkan-radeon"
      "libvdpau-va-gl"
      "lib32-vulkan-radeon"
    )
    ;;

  *UHD* | *Iris* | *Arc* | *"HD Graphics"*)
    _log_info "Installing Intel GPU drivers"
    PACKAGES+=(
      "mesa"
      "nvtop"
      "lib32-mesa"
      "vulkan-intel"
      "lib32-vulkan-intel"
    )

    case "$VGA_STR" in
      # Broadwell (2014) and newer
      *Broadwell* | *Skylake* | *"Kaby Lake"* | *"Coffee Lake"* | *"Comet Lake"* | *"Ice Lake"* | *"Tiger Lake"* | *"Alder Lake"* | *"Raptor Lake"* | *Arc*)
        PACKAGES+=("intel-media-driver")
        ;;

      # GMA 4500 (2008) up to pre-Broadwell
      *Penryn* | *Nehalem* | *Westmere* | *"Sandy Bridge"* | *"Ivy Bridge"* | *Haswell*)
        PACKAGES+=("libva-intel-driver")
        ;;
    esac

    case "$VGA_STR" in
      *"Tiger Lake"* | *"Alder Lake"* | *"Raptor Lake"*)
        PACKAGES+=("vpl-gpu-rt")
        ;;

      *)
        PACKAGES+=("intel-media-sdk")
        ;;
    esac
    ;;
  *"Red Hat"* | *Virtio*)
    :
    ;;
  *)
    _log_warn "No supported GPU detected. Please install the drivers manually."
    _log_warn "If you believe this is an error, consider opening an issue."
    ;;
esac

if ((${#PACKAGES[@]} > 0)); then
  InstallPackages "${PACKAGES[@]}"
fi

if [[ "$NVIDIA_SETUP_NEEDED" == true ]]; then
  touch /tmp/nvidia-setup-needed
fi
