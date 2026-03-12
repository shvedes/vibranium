#!/usr/bin/env bash

P_YELLOW='#e0af68'

msg="\nPress <span foreground='${P_YELLOW}'><b>SUPER + A</b></span>      to open app launcher\n"
msg+="Press <span foreground='${P_YELLOW}'><b>CTRL + ALT + V</b></span> to open Vibranium menu\n\n"
msg+="<b>Right-click</b> to dismiss this notification\n"
notify-send -r $RANDOM -t 1800000 "Welcome to Vibranium" "$msg"

