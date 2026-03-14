#!/usr/bin/env bash

msg="\nPress <span foreground='#e0af68'><b>SUPER + A</b></span>      to open app launcher\n"
msg+="Press <span foreground='#e0af68'><b>CTRL + ALT + V</b></span> to open Vibranium menu\n\n"
msg+="<b>Right-click</b> to dismiss all notifications\n"
notify-send -r $RANDOM -t 1800000 "Welcome to Vibranium" "$msg"
