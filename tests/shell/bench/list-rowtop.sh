#!/bin/bash
# Benchmark: List.rowTop's prefix walk, old implementation vs the row-set
# identity projection. See list-rowtop.qml for what is compared.
#
#   bash tests/shell/bench/list-rowtop.sh

set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BENCH_DIR/../lib/lib.sh"
source "$BENCH_DIR/../lib/qmlprobe.sh"

trap qp_teardown EXIT

if ! qp_run "$BENCH_DIR/list-rowtop.qml" 120; then
  echo "the probe did not finish:" >&2
  qp_out >&2
  exit 1
fi

sed -n 's/.*##KV## /  /p' < <(qp_out)
