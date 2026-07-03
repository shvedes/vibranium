#!/bin/bash

helpers::check VIBRANIUM_GLOBAL_APP_LAUNCHER_SHOW_ON_START
if [[ $VIBRANIUM_GLOBAL_APP_LAUNCHER_SHOW_ON_START = true ]]; then
  setsid -f vb-core-launcher
fi
