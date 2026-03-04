#!/bin/bash

# This script has been copy-pasted from https://github.com/Maciejonos/dotfiles.git.
# All credits to the owner of the repo

set -e

INSTALL_DIR="$HOME/.local/share/vibranium"
REPO_URL="https://github.com/shvedes/vibranium"

# Check if vibranium directory already exists
if [ -d "$INSTALL_DIR" ]; then
    echo "ERROR: $INSTALL_DIR already exists!" >&2
    echo "If you want to reinstall, please remove or backup the existing directory first:" >&2
    echo "  mv ~/.local/share/vibranium ~/.local/share/vibranium.backup" >&2
    exit 1
fi

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Git is not installed. Installing git..."
    sudo pacman -S --noconfirm git
    echo "Git installed successfully!"
fi

# Create .config directory if it doesn't exist
mkdir -p "$HOME/.config"

# Create .local/share/vibranium directory
mkdir -p "$HOME/.local/share/vibranium"

# Clone the vibranium repository
echo "Cloning vibranium repository..."
latest_ver="$(git ls-remote --tags --sort="v:refname" "$REPO_URL" | tail -n1)"
latest_ver="$(sed 's|.*refs/tags/||;s|\^{}||' <<< "$latest_ver")"
git clone --branch "$latest_ver" "$REPO_URL" "$INSTALL_DIR"

echo
echo "Repository cloned successfully!"
echo "Starting installation..."
echo

sleep 2

# Run the installer
exec bash "$INSTALL_DIR/install/install"
