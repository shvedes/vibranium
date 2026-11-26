#!/bin/bash
# Gate 2: raw offer and real-gateway registration parity, baseline vs candidate.
#
#   bash tests/shell/bench/unit-pilot/registration-parity-test.sh
#
# The baseline is exported from the pinned commit into an isolated immutable
# tree with `git archive`. The candidate is a snapshot of the current shell/
# tree in a second isolated directory. Neither tree is written to: each run
# uses a throwaway mirror that swaps only the PanelWindow layer primitive for
# an inert Item, so the REAL singletons and the REAL IpcRouter can be observed
# offscreen without touching the live desktop.
set -uo pipefail

PILOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PILOT_DIR/../../lib/lib.sh"
source "$PILOT_DIR/../../lib/harness.sh"
source "$PILOT_DIR/../../lib/qmlprobe.sh"
source "$PILOT_DIR/mirror-lib.sh"

BASELINE_COMMIT="9c3b2828"
REPORT_DIR="${VB_PILOT_REPORT_DIR:-/tmp/opencode/vibranium-pilot-reports}"
WORK="$REPORT_DIR/gate2-trees"
mkdir -p "$WORK"

t_init "unit-pilot/registration-parity" "baseline $BASELINE_COMMIT vs candidate, three observation points"
pilot_require_qs
require_tools git node tar

BASE_TREE="$WORK/baseline"
CAND_TREE="$WORK/candidate"
BASE_MIRROR="$WORK/baseline-mirror"
CAND_MIRROR="$WORK/candidate-mirror"

# Rebuild both isolated trees on every run so a previous run cannot leak.
rm -rf "$BASE_TREE" "$CAND_TREE" "$BASE_MIRROR" "$CAND_MIRROR"
mkdir -p "$BASE_TREE" "$CAND_TREE"
if ! git archive "$BASELINE_COMMIT" | tar -x -C "$BASE_TREE"; then
  printf 'BLOCKED: could not export baseline %s\n' "$BASELINE_COMMIT" >&2
  exit 77
fi
if ! cp -a "$VIBRANIUM_DIR/shell" "$CAND_TREE/shell"; then
  printf 'BLOCKED: could not snapshot the candidate shell tree\n' >&2
  exit 77
fi

printf 'baseline commit: %s\n' "$(git rev-parse "$BASELINE_COMMIT")"
printf 'baseline shell/catalog.js: %s\n' \
  "$(sha256sum "$BASE_TREE/shell/boot/Units.catalog.js" | cut -d' ' -f1)"
printf 'candidate HEAD: %s\n' "$(git rev-parse HEAD)"
printf 'candidate shell/catalog.js: %s\n' \
  "$(sha256sum "$CAND_TREE/shell/boot/Units.catalog.js" | cut -d' ' -f1)"

pilot_mirror "$BASE_MIRROR" "$BASE_TREE/shell"
pilot_mirror "$CAND_MIRROR" "$CAND_TREE/shell"
# Both mirrors use byte-exact generated rows; the repaired generator emits
# Qt.createComponent(...) hook construction, so no adaptation is needed.

BASE_OUT="$REPORT_DIR/gate2-baseline.kv.txt"
CAND_OUT="$REPORT_DIR/gate2-candidate.kv.txt"
COMPARE_OUT="$REPORT_DIR/gate2-comparison.json"

base_rc=0
cand_rc=0
pilot_run "$BASE_MIRROR" "$PILOT_DIR/registration-parity-probe.qml" 30 "$BASE_OUT" "baseline" || base_rc=$?
qp_teardown
pilot_run "$CAND_MIRROR" "$PILOT_DIR/registration-parity-probe.qml" 30 "$CAND_OUT" "candidate" || cand_rc=$?
qp_teardown

printf 'baseline run rc=%s  candidate run rc=%s\n' "$base_rc" "$cand_rc"
printf '%s\n' "--- baseline serialized observations ($BASE_OUT) ---"
grep '##KV##' "$BASE_OUT" | sed 's/^.*##KV## //'
printf '%s\n' "--- candidate serialized observations ($CAND_OUT) ---"
grep '##KV##' "$CAND_OUT" | sed 's/^.*##KV## //'

if ((base_rc != 0 || cand_rc != 0)); then
  t_no "both probes reached ##DONE##" "baseline rc=$base_rc, candidate rc=$cand_rc"
  t_summary
  exit $?
fi

# Guard: a candidate half that failed to construct has no observations to
# compare, so the gate must be BLOCKED rather than reported as a parity result.
cand_providers="$(printf '%s,%s' \
  "$(grep '##KV## providers.object.services=' "$CAND_OUT" | sed 's/.*=//')" \
  "$(grep '##KV## providers.object.features=' "$CAND_OUT" | sed 's/.*=//')")"
if [[ $cand_providers != true,true ]]; then
  t_block "candidate late providers did not load; candidate providers=$cand_providers"
fi

t_section "probe preconditions"
t_eq "instance label is identical" "$(grep '##KV## instance=' "$BASE_OUT" | sed 's/.*=//')" \
  "$(grep '##KV## instance=' "$CAND_OUT" | sed 's/.*=//')"
t_eq "baseline probe had no error" "false" \
  "$(grep -q '##KV## probe.error=' "$BASE_OUT" && printf true || printf false)"
t_eq "candidate probe had no error" "false" \
  "$(grep -q '##KV## probe.error=' "$CAND_OUT" && printf true || printf false)"
t_eq "baseline providers loaded" "true,true" \
  "$(printf '%s,%s' \
    "$(grep '##KV## providers.object.services=' "$BASE_OUT" | sed 's/.*=//')" \
    "$(grep '##KV## providers.object.features=' "$BASE_OUT" | sed 's/.*=//')")"
t_eq "candidate providers loaded" "true,true" \
  "$(printf '%s,%s' \
    "$(grep '##KV## providers.object.services=' "$CAND_OUT" | sed 's/.*=//')" \
    "$(grep '##KV## providers.object.features=' "$CAND_OUT" | sed 's/.*=//')")"

t_section "observation equality"
if node "$PILOT_DIR/compare-observations.mjs" "$BASE_OUT" "$CAND_OUT" >"$COMPARE_OUT"; then
  t_ok "all three observation points are equal" "$(cat "$COMPARE_OUT")"
else
  t_no "all three observation points are equal" "$(cat "$COMPARE_OUT")"
fi
printf '%s\n' "--- comparison artifact ($COMPARE_OUT) ---"
cat "$COMPARE_OUT"

t_summary
