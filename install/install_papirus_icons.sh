#!/usr/bin/env bash

set -euo pipefail

# Due to the active use of the papirus-folders script, 
# we need to keep the Papirus icon pack accessible for writing by regular users in order to avoid constant use of sudo.

CWD="$(pwd)"

echo "Installing Papirus icon theme"
cd ~/.cache
git clone https://github.com/PapirusDevelopmentTeam/papirus-icon-theme
cd papirus-icon-theme
mkdir -p "$HOME/.local/share/icons"
cp -r Papirus* "$HOME"/.local/share/icons
echo "Papirus icon theme installed"

echo "Downloading papirus-folders"
mkdir -p "$HOME/.local/bin"
curl -s https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/refs/heads/master/install.sh -o "$HOME/.local/bin/papirus-folders"
chmod +x "$HOME/.local/bin/papirus-folders"
echo "papirus-folders installed"

cd "$CWD"
