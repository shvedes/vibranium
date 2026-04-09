#!/usr/bin/env bash

if [[ -f "$VIBRANIUM_STATE/secure-boot-setup.complete" ]]; then
  rm "$VIBRANIUM_STATE/secure-boot-setup.complete"

  SB_STATE="$(vb-cmd-sboot-status)"

  if [[ "$SB_STATE" == "enabled" ]]; then
    notify-send -r 1 -t 10000 "Secure Boot Setup Wizard" "Secure Boot setup complete!"
  elif [[ "$SB_STATE" == "setup" ]]; then
    msg="Secure Boot is still in Setup mode!"
    msg+="Is your firmware poorly implemented?"
    notify-send -r 1 -t 60000 -u critical "Secure Boot Setup Wizard" "$msg"
  elif [[ "$SB_STATE" == "disabled" ]]; then
    msg="Secure Boot setup did not complete properly!\n"
    msg+="See 'sbctl status' for detailed info"
    notify-send -r 1 -t 60000 -u critical "Secure Boot Setup Wizard" "$msg"
  fi
fi
