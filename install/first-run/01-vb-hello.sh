#!/bin/bash

msg="<b>SUPER + A</b> to open app launcher\n"
msg+="<b>CTRL + ALT + V</b> to open Vibranium menu"

notify-send -a "Vibranium" -r $RANDOM -t 0 \
  "Welcome to Vibranium" "$msg"
