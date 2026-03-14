#!/usr/bin/env bash

# The idea is taken from Omarchy.
# All cretids to the Omarchy contributors, not me.
# This is just an adoptation.

if [[ "$CHASSIS_TYPE" == vm ]]; then
  exit 0
fi

if ! term::ask_yes_no N "Would you like to setup CUPS printing service?"; then
  exit 0
fi

InstallPackages cups cups-browsed

# Disable multicast dns in resolved. Avahi will provide this for better network printer discovery
sudo mkdir -p /etc/systemd/resolved.conf.d
echo -e "[Resolve]\nMulticastDNS=no" | sudo tee /etc/systemd/resolved.conf.d/10-disable-multicast.conf > /dev/null

# Enable mDNS resolution for .local domains
sudo sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve files myhostname dns/' /etc/nsswitch.conf

# Enable automatically adding remote printers
if ! grep -q '^CreateRemotePrinters Yes' /etc/cups/cups-browsed.conf; then
  echo 'CreateRemotePrinters Yes' | sudo tee -a /etc/cups/cups-browsed.conf > /dev/null
fi

sudo systemctl -q enable cups cups-browsed avahi-daemon
UpdateSummary "User choice: enabled CUPS printing service with network printer discovery"
