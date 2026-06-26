#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

vb-tui-install \
  --exec vb-cmd-manpager \
  --name 'Man Page Viewer' \
  --category 'Utilities;System' \
  --float
