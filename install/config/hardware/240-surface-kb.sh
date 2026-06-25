#!/usr/bin/bash

# Credits: Omarchy

if [[ "$(</sys/class/dmi/id/sys_vendor 2>/dev/nukk)" == "Microsoft Corporation" ]]; then
  if ! vb-hw-match "Surface"; then
    exit 1
  fi

  helpers::log::info "Detected ${CYAN}Microsoft Surface${RESET} laptop"
  helpers::log::info "Attempting to autodetect required ${CYAN}pinctrl${RESET} module"

  PINCTRL_MODULE=$(lsmod | grep pinctrl_ | cut -f 1 -d" ")

  if [[ -z $PINCTRL_MODULE ]]; then
    helpers::log::warn "Failed to autodetect pinctrl module."
  else
    helpers::log::info "Detected pinctrl module: ${CYAN}${PINCTRL_MODULE}${RESET}"
  fi

  helpers::write_file /etc/mkinitcpio.conf.d/vb-surface-kbd.conf <<EOF
  # This file was created by Vibranium installer.
  MODULES=(${PINCTRL_MODULE} surface_aggregator surface_aggregator_registry surface_aggregator_hub surface_hid_core surface_hid surface_kbd intel_lpss_pci 8250_dw)
EOF
fi
