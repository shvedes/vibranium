#!/usr/bin/env bash

if [[ ! -f /tmp/nvidia-setup-needed ]]; then
  exit 0
fi

MKINITCPIO_CONF="/etc/mkinitcpio.conf"
NVIDIA_MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"

helpers::log::info "Configuring NVIDIA drivers (this may take a moment)"

helpers::log::info "Updating mkinitcpio.conf"
# Remove any old nvidia modules to prevent duplicates
vb::sed "$MKINITCPIO_CONF" -E 's/ nvidia_drm//g; s/ nvidia_uvm//g; s/ nvidia_modeset//g; s/ nvidia//g;'

# Add the new modules at the start of the MODULES array
vb::sed "$MKINITCPIO_CONF" -E "s/^(MODULES=\\()/\\1${NVIDIA_MODULES} /"

# Clean up potential double spaces
vb::sed "$MKINITCPIO_CONF" -E 's/  +/ /g'

helpers::log::info "Generating mkinitcpio image"
if ! sudo mkinitcpio -P &> /dev/null; then
  helpers::log::error "mkinitcpio -P failed"
  rm -f /tmp/nvidia-setup-needed
  exit 1
fi

rm -f /tmp/nvidia-setup-needed
