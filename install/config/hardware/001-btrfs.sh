#!/usr/bin/bash

while read -r fstype; do
  if [[ "$fstype" == "btrfs" ]]; then
    helpers::log::info "Btrfs filesystem detected on the system"
    printf "%s\n" "btrfs-progs" "compsize" >> /tmp/vibranium.packages
    break
  fi
done < <(lsblk -n -o FSTYPE 2>/dev/null)
