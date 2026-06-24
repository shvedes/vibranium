#!/usr/bin/env bash

shell="$(</tmp/shell)"

if [[ "$shell" == "bash" ]]; then
  exit 0
else
  helpers::log::info "Setting up shell"
fi

sudo usermod --shell /usr/bin/$shell $USER
