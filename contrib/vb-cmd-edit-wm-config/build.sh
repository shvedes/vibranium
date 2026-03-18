#!/usr/bin/env bash

set -euo pipefail

INSTALL_DIR="$HOME/.local/share/vibranium/bin"
BINARY="vb-cmd-edit-wm-config"

cargo build --quiet --release

mkdir -p "$INSTALL_DIR"
cp "target/release/$BINARY" "$INSTALL_DIR/$BINARY"
