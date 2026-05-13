#!/bin/bash

sudo pacman -S gnome-keyring
systemctl --user start gnome-keyring-daemon.socket
