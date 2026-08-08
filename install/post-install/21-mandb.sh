#!/usr/bin/bash

helpers::log::info "Generating man pages"
sudo mandb --create --quiet
