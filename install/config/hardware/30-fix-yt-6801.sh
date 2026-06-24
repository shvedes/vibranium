#!/usr/bin/env bash

# Copy-pasted from Omarchy.

# Install drivers for Motorcomm YT6801 ethernet adapter used by the Slimbook Executive
if lspci | grep -i "YT6801\|Motorcomm.*Ethernet"; then
  helpers::log::info "Installing drivers for Motorcomm YT6801 Ethernet adapter"
  helpers::install_pkg linux-headers yt6801-dkms
fi
