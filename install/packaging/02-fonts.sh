#!/usr/bin/env bash

mapfile -t packages < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-fonts.pkgs")

_log_info "Installing fonts"
InstallPackages "${packages[@]}"
