#!/usr/bin/env bash

if [[ "$CHASSIS_TYPE" == "vm" ]]; then
  exit 0
fi

SB_STATE="$(vb-cmd-sboot-status)"

if [[ -f "$VIBRANIUM_STATE/secure-boot-setup.complete" ]]; then
  rm "$VIBRANIUM_STATE/secure-boot-setup.complete"

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
else
  if [[ "$SB_STATE" == "setup" ]]; then
    STATE="$VIBRANIUM_STATE/sboot-notify.ignore"
    if [[ ! -f "$STATE" ]]; then
      msg="Secure Boot is disabled. Enable it in Vibranium Menu > Setup > Secure Boot\n\n"
      msg+="Left-click to disable this message on startup\n"
      msg+="Right-click to hide it until next login"
      ACTION=$(notify-send --action=true -r 1 -t 60000 "UEFI Firmware In Setup Mode" "$msg")

      if [[ -n "$ACTION" ]]; then
        notify-send -r 1 -t 3000 "Vibranium" "Secure Boot notice has been disabled"
        : >"$STATE"
      fi
    fi
  fi
fi
