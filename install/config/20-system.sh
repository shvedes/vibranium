#!/usr/bin/env bash

VIBRANIUM="$HOME/.local/share/vibranium"

# pacman hooks
# polkit rule (sudoless mounting)
# v4l loopback (aka virtual camera)
sudo cp -r "$VIBRANIUM"/extras/etc/* /etc/

# Power plug / USB notifications
sudo cp -r "$VIBRANIUM"/extras/etc/udev/rules.d /etc/udev/

# Auxiliary scripts (executed by the udev)
sudo cp -r "$VIBRANIUM"/extras/usr/local/bin/* /usr/local/bin/
sudo sed -i "s/user_placeholder/$USER/g" /usr/local/bin/*

UpdateSummary "System / pacman: added custom pacman hooks"
UpdateSummary "System / polkit: added rules for sudoless mounting"
UpdateSummary "System / udev: added power plug and USB notification rules"
UpdateSummary "System / scripts: added auxiliary udev scripts"
