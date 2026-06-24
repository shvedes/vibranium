#!/usr/bin/env bash

PACKAGES=()
ROOT_FS="$(findmnt -n -o FSTYPE /)"

if [[ "$ROOT_FS" == "btrfs" ]]; then
  PACKAGES+=(btrfs-progs compsize)
fi

total_diskks="$(lsblk -f)"

if [[ "$total_diskks" =~ ntfs ]]; then
  PACKAGES+=(ntfs-3g)
fi

if [[ "$total_diskks" =~ nvme ]]; then
  PACKAGES+=(nvme-cli)
fi

if ((${#PACKAGES[@]} > 0)); then
  helpers::install_pkg "${PACKAGES[@]}"
fi
