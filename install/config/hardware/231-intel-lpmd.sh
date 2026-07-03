#!/bin/bash

IFS="'" read -r CPU_VENDOR CPU_CODE < <(vb-hw-cpu -qvc)

if [[ "$CPU_VENDOR" == "Intel" ]] && [[ "$CPU_CODE" =~ ^(151|154|170|172|183|186|189|191|204)$ ]]; then
  if vb-hw-battery; then
    helpers::log::info "Intel: installing Lower Power Mode Daemon (LPMD)"
    helpers::install_pkg intel-lpmd
    sudo systemctl -q enable intel_lpmd.service
  fi
fi
