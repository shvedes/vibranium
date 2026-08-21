#!/usr/bin/bash

YELLOW=$'\e[0;33m'
BLUE=$'\e[0;34m'
GREEN=$'\e[0;32m'
RED=$'\e[0;31m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

file="$XDG_CONFIG_HOME/vibranium/settings.advanced"
theme="$(<$XDG_CONFIG_HOME/vibranium/current/theme.name)"

awk '
/^[[:space:]]*vb_force_template_files=\([[:space:]]*$/ {
  print
  print "  # The template system does a good job of generating Hyprland'\''s appearance."
  print "  # If you disable it, keep in mind that some community themes define"
  print "  # their own animation curves. In such cases, the animation setting shown in"
  print "  # Vibranium settings may not match the animations actually being used."
  print "  \"hyprland.lua\""
  print ""
  next
}
{ print }
' "$file" >"$file.tmp" && mv "$file.tmp" "$file"

vb-theme-set --force "$theme"

echo "${RED}[MIGRATION|$SELF]${RESET} If you've installed a community theme,"
echo "${RED}[MIGRATION|$SELF]${RESET} keep in mind that, from now on, Hyprland's appearance"
echo "${RED}[MIGRATION|$SELF]${RESET} will be generated exclusively by the template system."
echo "${RED}[MIGRATION|$SELF]${RESET}"
echo "${RED}[MIGRATION|$SELF]${RESET} If you do not want this behavior, please manually remove the ${YELLOW}\"hyprland.lua\"${RESET}"
echo "${RED}[MIGRATION|$SELF]${RESET} entry from the ${YELLOW}\$vb_force_template_files${RESET} array in ${BLUE}~/.config/vibranium/settings.advanced${RESET}."
echo "${RED}[MIGRATION|$SELF]${RESET}"
echo "${RED}[MIGRATION|$SELF]${RESET} If you have no idea what you've just read, feel free to ignore this message."
