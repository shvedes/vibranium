#!/usr/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

cp $VIBRANIUM/extras/icons/Vibranium/scalable/actions/vb-inhibitor.svg \
  "$XDG_DATA_HOME"/icons/Vibranium/scalable/actions/
