#!/usr/bin/env bash

VIBRANIUM="$HOME/.local/share/vibranium"
STATE_DIR="$HOME/.local/state/vibranium/migrations"
MIGRATIONS_DIR="$VIBRANIUM/migrations"

_log_info "Setting up migrations"
mkdir -p "$STATE_DIR"

for file in "$MIGRATIONS_DIR"/*.sh; do
  : > "$STATE_DIR/"${file##*/}""
done

UpdateSummary "Migrations: created state tracking files for all available migration scripts"
