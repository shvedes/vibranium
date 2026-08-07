#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

cat <<- EOF >> "$XDG_CONFIG_HOME/vibranium/environment"

# If running on a real hardware, Vibranium will set all the GPU/graphics
# related special environment variables for you automatically.
# This file lives in the Vibranium installation folder, so do not edit it.
# If you don't need it - just remove or comment out this line.
# Variables:
#
#   NVIDIA:
#                      WLR_NO_HARDWARE_CURSORS
#                      NVD_BACKEND
#                      GBM_BACKEND
#                      __GLX_VENDOR_LIBRARY_NAME
#
#   AMD/Intel/NVIDIA:
#                     LIBVA_DRIVER_NAME
#                     VDPAU_DRIVER
#
if ! [[ "$CHASSIS_TYPE" == "vm" ]]; then
  source "\$VIBRANIUM/default/uwsm/gpu-env"
fi
EOF
