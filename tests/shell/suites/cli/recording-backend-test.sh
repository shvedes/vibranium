#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "recording-backend" "recording lifecycle with a fake encoder and real gsr-cli"
require_tools python3 gsr-cli jq flock timeout

t_true "start, stop, fallback and crash handling work over the private control socket" \
  python3 "$TESTS_SHELL_DIR/suites/cli/fixtures/recording-backend.py" "$VIBRANIUM_DIR"

t_summary
