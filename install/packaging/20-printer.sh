#!/usr/bin/env bash

if [[ "$CHASSIS_TYPE" == vm ]]; then
  exit 0
fi

if ! term::ask_yes_no N "Would you like to setup CUPS service (printer support)?"; then
  exit 0
fi

packages=(
  cups
  cups-pdf
  cups-browsed
  cups-filters

  # https://wiki.archlinux.org/title/CUPS#Printer_drivers
  gutenprint
  foomatic-db
  foomatic-db-ppds
  foomatic-db-nonfree
  foomatic-db-nonfree-ppds
  foomatic-db-gutenprint-ppds
)

for pkg in "${packages[@]}"; do
  printf "%s\n" "$pkg" >> /tmp/vibranium.packages
done
