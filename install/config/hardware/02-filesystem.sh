#!/usr/bin/env bash

PACKAGES=()
ROOT_FS="$(findmnt -n -o FSTYPE /)"

if [[ "$ROOT_FS" == "btrfs" ]]; then
  _log_info "Detected BTRFS on root partition."
  _log_info "It's recommended to install extra tools for your filesystem."
  _log_info "These can be useful for maintenance and troubleshooting tasks."

  if term::ask_yes_no Y "Would you like to install them?"; then
    PACKAGES+=(btrfs-progs compsize)
  fi
fi

if [[ "$(lsblk -f)" =~ ntfs ]]; then
  _log_info "NTFS partition detected"

  if term::ask_yes_no Y "Do you want to install NTFS driver?"; then
    _log_success "You will be able to access your NTFS partition without issues."
    _log_success "Make sure Fast Boot is disabled in Windows settings,"
    _log_success "otherwise the partition will be mounted as read-only."

    PACKAGES+=(ntfs-3g)
  fi
fi

if ((${#PACKAGES[@]} > 0)); then
  UpdateSummary "general: installed ${PACKAGES[@]} (user's choise)"
  InstallPackages "${PACKAGES[@]}"
fi
