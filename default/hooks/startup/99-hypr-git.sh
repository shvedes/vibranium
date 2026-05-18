#!/bin/bash

ver="$(pacman -Q hyprland | awk '{print $2}')"

if [[ $ver == *r* ]]; then
  if [[ $(git -C "$VIBRANIUM" branch --show-current) =~ ^(dev|master)$ ]]; then
    notify-send -r 1 -t 20000 "Vibranium" "
You're running on git version of Hyprland.
Plese note that some things might brake or not work at all.

It's recommended to switch Vibranium release channel to dev.
You can do it in Vibranium Menu > Settings > General."
  fi
fi
