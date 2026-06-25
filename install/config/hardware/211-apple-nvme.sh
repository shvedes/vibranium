#!/usr/bin/env bash

# Copy-pasted from Omarchy.
# Not my work.

# Fix NVMe suspend issues on MacBook models
# This prevents NVMe drives from failing to wake from sleep properly
MACBOOK_MODEL=$(</sys/class/dmi/id/product_name 2>/dev/null)

if [[ -z $MACBOOK_MODEL ]]; then
  exit 0
fi

if [[ $MACBOOK_MODEL =~ MacBook(8,1|9,1|10,1)|MacBookPro13,[123]|MacBookPro14,[123] ]]; then
  helpers::log::info "Detected MacBook model: $MACBOOK_MODEL"

  NVME_DEVICE="/sys/bus/pci/devices/0000:01:00.0/d3cold_allowed"

  if [[ -f $NVME_DEVICE ]]; then
    helpers::log::info "Apple: applying suspend fix"


    helpers::write_file /etc/systemd/system/apple-nvme-suspend-fix.service <<-EOF
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
