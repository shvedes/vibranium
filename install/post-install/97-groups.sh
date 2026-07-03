#!/bin/bash

groups=(wheel audio video storage network realtime)

if command -v docker >/dev/null; then
  groups+=(docker)
fi

if command -v virsh >/dev/null; then
  groups+=(libvirt)
fi

IFS=,
sudo usermod -aG "${groups[*]}" "$USER"
