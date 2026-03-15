#!/usr/bin/env bash

mapfile -t packages < /tmp/vibranium.packages
InstallPackages --verify "${packages[@]}"
