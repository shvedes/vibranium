#!/usr/bin/env bash

# Wait for pipewire to start
while ! pidof -q pipewire; do
  sleep 0.1
done

# The loopback will be disabled by default because we're creating it
# in runtime without permanent configurations, so we need to restore it this way.
helpers::check VIBRANIUM_VOLUME_SOURCE_LOOPBACK
if [[ $VIBRANIUM_VOLUME_SOURCE_LOOPBACK == true ]]; then
  vb-cmd-toggle-loopback
fi
