#!/usr/bin/env bash

# Copy-pasted from Omarchy.
# Not my work.

# Fix NVMe suspend issues on MacBook models
# This prevents NVMe drives from failing to wake from sleep properly
MACBOOK_MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)

if [[ $MACBOOK_MODEL =~ MacBook(8,1|9,1|10,1)|MacBookPro13,[123]|MacBookPro14,[123] ]]; then
  _log_info "Detected MacBook model: $MACBOOK_MODEL"

  NVME_DEVICE="/sys/bus/pci/devices/0000:01:00.0/d3cold_allowed"

  if [[ -f $NVME_DEVICE ]]; then
    _log_info "Applying suspend fix"

    cat <<EOF | sudo tee /etc/systemd/system/apple-nvme-suspend-fix.service >/dev/null
[Unit]
Description=NVMe Suspend Fix for MacBook

[Service]
ExecStart=/bin/bash -c 'echo 0 > /sys/bus/pci/devices/0000\:01\:00.0/d3cold_allowed'

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl -q daemon-reload
    sudo systemctl -q enable apple-nvme-suspend-fix.service
  fi
fi
