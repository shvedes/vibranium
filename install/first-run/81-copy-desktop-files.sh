#!/usr/bin/env bash

# Archive Manager
cp /usr/share/applications/xarchiver.desktop ~/.local/share/applications
sed -i '/Name=/s/Name=.*/Name=Archive Manager/' ~/.local/share/applications/xarchiver.desktop
