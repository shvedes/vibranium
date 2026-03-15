#!/usr/bin/env bash

# Copy-pasted from Omarchy.

# Install drivers for Motorcomm YT6801 ethernet adapter used by the Slimbook Executive
if lspci | grep -i "YT6801\|Motorcomm.*Ethernet"; then
  _log_info "Installing drivers for Motorcomm YT6801 Ethernet adapter"
  InstallPackages linux-headers yt6801-dkms
fi
