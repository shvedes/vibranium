#!/bin/bash

while read -r fstype; do
  if [[ "$fstype" == "ntfs" || "$fstype" == "ntfs3" || "$fstype" == "fuseblk" ]]; then
    helpers::log::info "NTFS filesystem detected on the system"
    echo "ntfs-3g" >> /tmp/vibranium.packages
    break
  fi
done < <(lsblk -n -o FSTYPE 2>/dev/null)
