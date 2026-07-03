#!/bin/bash

# Detect MacBook models that need SPI keyboard modules
product_name="$(< /sys/class/dmi/id/product_name)"
if [[ $product_name =~ MacBook[89],1|MacBook1[02],1|MacBookPro13,[123]|MacBookPro14,[123] ]]; then
  helpers::log::info "Detected MacBook with SPI keyboard"
  helpers::log::info "Added ${CYAN}macbook12-spi-driver-dkms${RESET} to the package queue"

  if [[ $product_name == "MacBook8,1" ]]; then
    echo "MODULES=(applespi spi_pxa2xx_platform spi_pxa2xx_pci)" | helpers::write_file /etc/mkinitcpio.conf.d/macbook_spi_modules.conf
  else
    echo "MODULES=(applespi intel_lpss_pci spi_pxa2xx_platform)" | helpers::write_file /etc/mkinitcpio.conf.d/macbook_spi_modules.conf
  fi
fi
