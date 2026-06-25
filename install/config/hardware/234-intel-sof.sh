#!/usr/bin/bash

# Credits: Omarchy

if [[ "$(vb-hw-cpu -ql)" =~ ^(Rocket|Alder|Raptor|Panther) Lake$ ]] && ! vb-hw-match "XPS"; then
  helpers::install_pkg sof-firmware
fi
