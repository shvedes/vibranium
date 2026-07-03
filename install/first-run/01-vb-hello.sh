#!/bin/bash

if [[ -f $VIBRANIUM_STATE/network-notify ]]; then
  notify-send -r $RANDOM -t 180000 "Network" "Click the Wifi icon to connect to the internet"
  rm $VIBRANIUM_STATE/network-notify
fi

msg="\nPress <span foreground='#e0af68'><b>SUPER + A</b></span>      to open app launcher\n"
msg+="Press <span foreground='#e0af68'><b>CTRL + ALT + V</b></span> to open Vibranium menu\n\n"
msg+="<b>Right-click</b> to close this notification\n"
notify-send -r $RANDOM -t 1800000 "Welcome to Vibranium" "$msg"
