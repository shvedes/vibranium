#!/bin/bash
#
# Register TIFF with the shell's image viewer. Fresh installs get this from
# install/first-run/11-mimetype.sh; installs predating that entry keep opening
# TIFF through whatever default the desktop picked. Idempotent: xdg-mime
# rewrites the same association on every run.

set -u

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

if command -v xdg-mime > /dev/null 2>&1; then
	if xdg-mime default image-viewer.desktop image/tiff; then
		echo "${GREEN}[MIGRATION|$SELF]${RESET} Registered image/tiff with image-viewer.desktop"
	else
		echo "${GREEN}[MIGRATION|$SELF]${RESET} Could not register image/tiff; set it manually with xdg-mime"
	fi
fi
