#!/usr/bin/env bash

shell="$(</tmp/shell)"

if [[ "$shell" == "bash" ]]; then
  exit 0
else
  _log_info "Setting up shell"
fi

sudo usermod --shell /usr/bin/$shell $USER
