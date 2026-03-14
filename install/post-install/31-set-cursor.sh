#!/usr/bin/env bash

if [[ -f /tmp/vibranium-set-cursor ]]; then
  vb-theme-cursor-set Bibata-Modern-Classic
  rm -f /tmp/vibranium-set-cursor
  UpdateSummary "Theme: set cursor theme to Bibata-Modern-Classic"
fi
