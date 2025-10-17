#!/usr/bin/env bash

mkdir -p "$HOME/.local/bin"

for file in ./extras/local/bin/*; do
	ln -s "$(realpath "$file")" "$HOME/.local/bin"
done
