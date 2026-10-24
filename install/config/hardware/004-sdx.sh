#!/bin/bash

while read -r _ _ _ name; do
  if [[ "$name" =~ (sda|hda) ]]; then
    helpers::log::info "SATA/IDE drive (sda/hda family) detected"
    echo "smartmontools" >> /tmp/vibranium.packages
    break
  fi
done < /proc/partitions
