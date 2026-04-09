#!/usr/bin/env bash

# Wait for pipewire to start
while ! pidof -q pipewire; do
  sleep 0.1
done

helpers::check VIBRANIUM_VOLUME_SOURCE_LOOPBACK
if [[ $VIBRANIUM_VOLUME_SOURCE_LOOPBACK == true ]]; then
  vb-cmd-toggle-loopback
fi
