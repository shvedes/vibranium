#!/usr/bin/env bash

if ! term::ask_yes_no N "Install additional filesystem utilities? (optional)"; then
  exit 0
fi

for pkg in dosfstools exfatprogs mtools; do
  printf "%s\n" "$pkg" >> /tmp/vibranium.packages
done

UpdateSummary "User choice: installed filesystem utilities"
