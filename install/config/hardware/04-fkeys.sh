#!/usr/bin/env bash

# Copy-pasted from Omarchy.
# For the sake of compatibility.

# Check if the machine is a MacBook
product_name="$(< /sys/class/dmi/id/product_name)"
if [[ $product_name =~ MacBook ]]; then
  # Ensure that F-keys on Apple keyboards are always F-keys
  if [[ ! -f /etc/modprobe.d/hid_apple.conf ]]; then
    echo "options hid_apple fnmode=2" | sudo tee /etc/modprobe.d/hid_apple.conf > /dev/null
    UpdateSummary "Apple / MacBook: configured hid_apple fnmode=2 to use F-keys as primary function keys"
  fi
fi
