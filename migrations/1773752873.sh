#!/usr/bin/env bash

vb-pkg-install --embedded -- realtime-privileges fish
sudo usermod --append --groups wheel,audio,video,network,realtime $USER
