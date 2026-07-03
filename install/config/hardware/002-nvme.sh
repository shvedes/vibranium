#!/bin/bash

while read -r major minor blocks name; do
  if [[ "$name" =~ nvme ]]; then
    helpers::log::info "NVMe hardware detected"
    echo "nvme-cli" >> /tmp/vibranium.packages
    break
  fi
done < /proc/partitions
