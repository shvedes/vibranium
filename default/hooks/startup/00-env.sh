#!/bin/bash

vars=()

while IFS='=' read -r key _; do
  vars+=("$key")
done < <(env)

systemctl --quiet --user import-environment "${vars[@]}" 2> /dev/null
dbus-update-activation-environment --systemd --all
uwsm finalize &> /dev/null
