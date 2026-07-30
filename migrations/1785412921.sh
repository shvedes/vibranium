#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

awk '
/^vb_force_template_files=\(/ { in_array=1 }
in_array && /^\)/ {
    print ""
    print "  # Always generate these files."
    print "  # Within the Vibranium ecosystem they have special semantics."
    print "  # For example, if a theme ships its own colors.lua, it will"
    print "  # break Hyprland theming because Vibranium depends on specific"
    print "  # variable names being present."
    print "  #"
    print "  # The same applies to colors.css and any applications that use"
    print "  # it for Vibranium-specific named color variables."
    print "  \"colors.lua\""
    print "  \"colors.css\""
    in_array=0
}
{ print }
' "$XDG_CONFIG_HOME/vibranium/settings.advanced" > /tmp/settings.advanced &&
  mv /tmp/settings.advanced "$XDG_CONFIG_HOME/vibranium/settings.advanced" &&
  rm /tmp/settings.advanced
