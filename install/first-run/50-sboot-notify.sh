#!/bin/bash

if [[ $(vb-cmd-sboot-status) != setup ]]; then
  exit 0
fi

(
  sleep 120
  notify-send -r $RANDOM -t 120000 "Secure Boot Setup" "
Looks like your firmware is in Setup Mode.
You can enable Secure Boot by going to Vibranium Menu > Setup > Secure Boot"
) &
