#!/usr/bin/env bash

yay -Rnsc yay-debug --noconfirm &> /dev/null || true
yay -Scc --noconfirm &> /dev/null
yay -Ycc --noconfirm &> /dev/null

UpdateSummary "Package manager: removed yay-debug package"
UpdateSummary "Package manager: cleaned yay build files and cache"
