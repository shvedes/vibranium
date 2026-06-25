#!/usr/bin/bash

# Credits: Omarchy

# Assume we're using UKIs.
# I have no Intel hardware ATM, so I can't
# verify if this works.

CMDLINE_FILE="/etc/kernel/cmdline"

if [[ "$(vb-hw-cpu -ql)" == "Panther Lake" ]]; then
  cmdline=""

  [[ -f $CMDLINE_FILE ]] && cmdline=$(<"$CMDLINE_FILE")

  if [[ ! " $cmdline " =~ [[:space:]]fred=on[[:space:]] ]]; then
    helpers::write_file "$CMDLINE_FILE" <<EOF
${cmdline:+$cmdline }fred=on
EOF
  fi
fi
