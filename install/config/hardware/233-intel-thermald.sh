#!/bin/bash

# Enable thermald for Intel laptops (Sandy Bridge and newer)
# Thermald is useful for Intel Sandy Bridge (2nd gen Core, model 42/45) and newer CPUs.

IFS="'" read -r CPU_VENDOR CPU_CODE < <(vb-hw-cpu -qvc)

if [[ "$CPU_VENDOR" == "Intel" ]] && (( CPU_CODE >= 42 )); then
  if vb-hw-battery; then
    helpers::install_pkg thermald
    sudo systemctl -q enable thermald
  fi
fi
