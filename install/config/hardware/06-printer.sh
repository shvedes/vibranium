#!/usr/bin/env bash

# Printing support (CUPS) and network printer/scanner discovery (Avahi).
# Source: Omarchy, adapted for Vibranium.

if vb::is_vm; then
  exit 0
elif ! term::ask_yes_no N "Install and configure printing support (CUPS, Avahi)?"; then
  exit 0
fi

packages=(
  cups
  nss-mdns
  cups-pdf
  cups-browsed
  cups-filters
  system-config-printer

  # https://wiki.archlinux.org/title/CUPS#Printer_drivers
  gutenprint
  foomatic-db
  foomatic-db-ppds
  foomatic-db-engine
  foomatic-db-nonfree
  foomatic-db-nonfree-ppds
  foomatic-db-gutenprint-ppds
)

helpers::install_pkg "${packages[@]}"

# Disable multicast DNS in resolved.
# Avahi will provide this instead, for better network printer discovery.
# https://wiki.archlinux.org/title/Avahi#Installation
vb::write_file /etc/systemd/resolved.conf.d/10-disable-multicast.conf << EOF2
[Resolve]
MulticastDNS=no
EOF2

# Enable mDNS resolution for .local domains
vb::sed /etc/nsswitch.conf 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve files myhostname dns/'

# Enable automatically adding remote printers
vb::append_once /etc/cups/cups-browsed.conf 'CreateRemotePrinters Yes' 'CreateRemotePrinters Yes'

sudo systemctl -q enable cups.service cups-browsed.service avahi-daemon.service
