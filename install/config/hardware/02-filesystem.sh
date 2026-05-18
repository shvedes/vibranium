#!/usr/bin/env bash

PACKAGES=()
ROOT_FS="$(findmnt -n -o FSTYPE /)"

if [[ "$ROOT_FS" == "btrfs" ]]; then
  PACKAGES+=(btrfs-progs compsize)
  UpdateSummary "System / Disks: installed BTRFS tools (btrfs-progs, compsize) - user choice"
fi

total_diskks="$(lsblk -f)"

if [[ "$total_diskks" =~ ntfs ]]; then
  PACKAGES+=(ntfs-3g)
  UpdateSummary "System / Disks: installed NTFS-3G driver for NTFS partition access - user choice"
fi

if [[ "$total_diskks" =~ nvme ]]; then
  PACKAGES+=(nvme-cli)
  UpdateSummary "System / Disks: installed nvme-cli disk utility (NVME disk detected)"
fi

if ((${#PACKAGES[@]} > 0)); then
  InstallPackages "${PACKAGES[@]}"
fi
