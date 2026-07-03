#!/bin/bash

if [[ "$(vb-hw-cpu -ql)" =~ ^(Rocket|Alder|Raptor|Panther)[[:space:]]Lake$ ]] && ! vb-hw-match "XPS"; then
  helpers::install_pkg sof-firmware
fi
