#!/usr/bin/env bash

if [[ ! -f /tmp/nvidia-setup-needed ]]; then
  exit 0
fi

MKINITCPIO_CONF="/etc/mkinitcpio.conf"
NVIDIA_MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"

_log_info "Configuring NVIDIA drivers (this may take a moment)"

sudo cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.bak

_log_info "Updating mkinitcpio.conf"
# Remove any old nvidia modules to prevent duplicates
sudo sed -i -E 's/ nvidia_drm//g; s/ nvidia_uvm//g; s/ nvidia_modeset//g; s/ nvidia//g;' "$MKINITCPIO_CONF"

# Add the new modules at the start of the MODULES array
sudo sed -i -E "s/^(MODULES=\\()/\\1${NVIDIA_MODULES} /" "$MKINITCPIO_CONF"

# Clean up potential double spaces
sudo sed -i -E 's/  +/ /g' "$MKINITCPIO_CONF"

_log_info "Generating mkinitcpio image"
if ! sudo mkinitcpio -P &> /dev/null; then
  _log_error "mkinitcpio -P failed"
  rm -f /tmp/nvidia-setup-needed
  exit 1
fi

rm -f /tmp/nvidia-setup-needed

UpdateSummary "nvidia: set up nvidia driver (kernel modules, mkinitcpio.conf edits)"
