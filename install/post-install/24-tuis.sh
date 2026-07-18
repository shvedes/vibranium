#!/bin/bash

helpers::log::info "Installing TUIs"

vb-tui-install \
  --exec btop \
  --name 'System Monitor' \
  --icon 'utilities-system-monitor' \
  --category 'System' \
  --keywords 'Resource;Network;Disk;GPU;Process'

vb-tui-install \
  --exec vb-launch-networkmanager \
  --name 'Wifi Manager' \
  --icon 'network-wireless-signal-excellent-symbolic' \
  --category 'System;Network'

vb-tui-install \
  --exec bluetui \
  --keywords 'Bt' \
  --name 'Bluetooth Manager' \
  --icon 'bluetooth-active-symbolic' \
  --category 'System'

vb-tui-install \
  --exec wiremix \
  --name 'Volume Control' \
  --icon 'org.pulseaudio.pavucontrol' \
  --category 'System'

vb-tui-install \
  --exec ncdu \
  --name 'Disk Usage Analyzer' \
  --icon 'filelight' \
  --category 'System' \
  --args '--enable-delete --exclude-kernfs --group-directories-first /'

vb-tui-install \
  --exec vb-util-yt-dlp \
  --name 'Video Downloader' \
  --category 'Utilities' \
  --float

vb-tui-install \
  --exec vb-cmd-manpager \
  --name 'Man Page Viewer' \
  --category 'Utilities;System' \
  --icon 'bookworm'
