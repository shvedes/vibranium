#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

sudo cp "$VIBRANIUM/extras/usr/local/bin/su-bridge" /usr/local/bin
