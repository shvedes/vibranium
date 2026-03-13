#!/usr/bin/env bash

yay -Rnsc yay-debug --noconfirm &> /dev/null || true
yay -Scc --noconfirm &> /dev/null
yay -Ycc --noconfirm &> /dev/null
