#!/bin/bash

AMD_AUDIO_CARD=

mapfile -t card_lines < <(pactl list cards 2>/dev/null)

for ((i = 0; i < ${#card_lines[@]}; i++)); do
  if [[ ${card_lines[i]} == *"Family 17h/19h"* ]]; then
    start=$((i - 20))
    ((start < 0)) && start=0

    for ((j = start; j <= i; j++)); do
      if [[ ${card_lines[j]} == *"Name: "* ]]; then
        AMD_AUDIO_CARD=${card_lines[j]#*Name: }
        break 2
      fi
    done
  fi
done

if [[ -n $AMD_AUDIO_CARD ]]; then
  pactl set-card-profile "$AMD_AUDIO_CARD" "HiFi (Mic1, Mic2, Speaker)" 2>/dev/null || true
fi
