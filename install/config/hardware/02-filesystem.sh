#!/usr/bin/env bash

PACKAGES=()
ROOT_FS="$(findmnt -n -o FSTYPE /)"

if [[ "$ROOT_FS" == "btrfs" ]]; then
  _log_info "Detected BTRFS on root partition."
  _log_info "It's recommended to install extra tools for your filesystem."
  _log_info "These can be useful for maintenance and troubleshooting tasks."

  PACKAGES+=(btrfs-progs compsize)
  UpdateSummary "System / Storage: installed BTRFS tools (btrfs-progs, compsize) - user choice"
fi

if [[ "$(lsblk -f)" =~ ntfs ]]; then
  PACKAGES+=(ntfs-3g)
  UpdateSummary "System / Storage: installed NTFS-3G driver for NTFS partition access - user choice"
fi

if ((${#PACKAGES[@]} > 0)); then
  InstallPackages "${PACKAGES[@]}"
fi
