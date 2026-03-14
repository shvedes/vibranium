#!/usr/bin/env bash

# Copy-pasted from Omarchy.
# For the sake of compatibility.

# Detect MacBook models that need SPI keyboard modules
product_name="$(< /sys/class/dmi/id/product_name)"
if [[ $product_name =~ MacBook[89],1|MacBook1[02],1|MacBookPro13,[123]|MacBookPro14,[123] ]]; then
  _log_info "Detected MacBook with SPI keyboard"
  _log_info "Added ${CYAN}macbook12-spi-driver-dkms${RESET} to the package queue"

  if [[ $product_name == "MacBook8,1" ]]; then
    echo "MODULES=(applespi spi_pxa2xx_platform spi_pxa2xx_pci)" | sudo tee /etc/mkinitcpio.conf.d/macbook_spi_modules.conf > /dev/null
    UpdateSummary "Apple / MacBook: configured SPI keyboard modules for MacBook8,1 (applespi, spi_pxa2xx_platform, spi_pxa2xx_pci)"
  else
    echo "MODULES=(applespi intel_lpss_pci spi_pxa2xx_platform)" | sudo tee /etc/mkinitcpio.conf.d/macbook_spi_modules.conf > /dev/null
    UpdateSummary "Apple / MacBook: configured SPI keyboard modules for MacBook model $product_name (applespi, intel_lpss_pci, spi_pxa2xx_platform)"
  fi
  UpdateSummary "Apple / MacBook: added macbook12-spi-driver-dkms to package queue for SPI keyboard support"
fi
