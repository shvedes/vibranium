#!/bin/bash

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

# Ask user which branch to clone
echo "Which version would you like to install?"
echo "  [1] release  - latest stable release (default)"
echo "  [2] dev      - development branch"
echo "  [3] upstream - master branch"
while true; do
    read -rp "Enter your choice [1/2/3] or press Enter for default: " branch_choice < /dev/tty

    case "${branch_choice:-1}" in
        1|"release")
            echo "Cloning vibranium repository (latest release)..."
            latest_ver="$(git ls-remote --tags --sort="v:refname" "$REPO_URL" | tail -n1)"
            latest_ver="$(sed 's|.*refs/tags/||;s|\^{}||' <<< "$latest_ver")"
            git clone --branch "$latest_ver" "$REPO_URL" "$INSTALL_DIR"
            break
            ;;
        2|"dev")
            echo "Cloning vibranium repository (dev branch)..."
            git clone --branch dev "$REPO_URL" "$INSTALL_DIR"
            break
            ;;
        3|"upstream")
            echo "Cloning vibranium repository (master branch)..."
            git clone --branch master "$REPO_URL" "$INSTALL_DIR"
            break
            ;;
        *)
            echo "Invalid choice: '$branch_choice'. Please enter 1, 2, or 3."
            ;;
    esac
done

echo
echo "Repository cloned successfully!"
echo "Starting installation..."
echo

sleep 2

# Run the installer
exec bash "$INSTALL_DIR/install/install"
