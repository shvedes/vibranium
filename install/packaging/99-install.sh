#!/usr/bin/env bash

mapfile -t packages < /tmp/vibranium.packages
helpers::install_pkg --verify "${packages[@]}"
