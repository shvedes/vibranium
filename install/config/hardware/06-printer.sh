#!/usr/bin/env bash

# Copy-pasted from Omarchy.

# Disable multicast dns in resolved.
# Avahi will provide this for better network printer discovery
sudo mkdir -p /etc/systemd/resolved.conf.d
echo -e "[Resolve]\nMulticastDNS=no" | sudo tee /etc/systemd/resolved.conf.d/10-disable-multicast.conf >/dev/null

# Enable mDNS resolution for .local domains
sudo sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve files myhostname dns/' /etc/nsswitch.conf

# Enable automatically adding remote printers
if ! grep -q '^CreateRemotePrinters Yes' /etc/cups/cups-browsed.conf; then
  echo 'CreateRemotePrinters Yes' | sudo tee -a /etc/cups/cups-browsed.conf >/dev/null
fi

sudo systemctl --quiet enable cups.service cups-browsed.service avahi-daemon.service
