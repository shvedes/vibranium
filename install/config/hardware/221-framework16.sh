#!/usr/bin/bash

# Source: Omarchy

if [[ $(</sys/class/dmi/id/sys_vendor) == "Framework" ]]; then
  if vb-hw-match "Laptop 16"; then
    helpers::write_file /etc/udev/rules.d/50-framework16-qmk-hid.rules <<-EOF
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", MODE="0660", TAG+="uaccess"
EOF
  fi
fi
