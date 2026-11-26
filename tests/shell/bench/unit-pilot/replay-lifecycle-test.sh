#!/bin/bash
# Gate 3: targeted replay/facade-lifecycle probe on both isolated trees, beside
# the read-only evidence from the existing boot-lease-probe suite.
#
#   bash tests/shell/bench/unit-pilot/replay-lifecycle-test.sh
set -uo pipefail

PILOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PILOT_DIR/../../lib/lib.sh"
source "$PILOT_DIR/../../lib/harness.sh"
source "$PILOT_DIR/../../lib/qmlprobe.sh"
source "$PILOT_DIR/mirror-lib.sh"

BASELINE_COMMIT="9c3b2828"
REPORT_DIR="${VB_PILOT_REPORT_DIR:-/tmp/opencode/vibranium-pilot-reports}"
WORK="$REPORT_DIR/gate3-trees"
mkdir -p "$WORK"

t_init "unit-pilot/replay-lifecycle" "decline/stash/replay parity and real appLauncher controller lifecycle"
pilot_require_qs
require_tools git node tar

BASE_TREE="$WORK/baseline"
CAND_TREE="$WORK/candidate"
BASE_MIRROR="$WORK/baseline-mirror"
CAND_MIRROR="$WORK/candidate-mirror"
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

pilot_mirror "$BASE_MIRROR" "$BASE_TREE/shell"
pilot_mirror "$CAND_MIRROR" "$CAND_TREE/shell"

BASE_OUT="$REPORT_DIR/gate3-baseline.kv.txt"
CAND_OUT="$REPORT_DIR/gate3-candidate.kv.txt"
COMPARE_OUT="$REPORT_DIR/gate3-replay-comparison.json"

base_rc=0
cand_rc=0
pilot_run "$BASE_MIRROR" "$PILOT_DIR/replay-lifecycle-probe.qml" 30 "$BASE_OUT" "baseline" || base_rc=$?
qp_teardown
pilot_run "$CAND_MIRROR" "$PILOT_DIR/replay-lifecycle-probe.qml" 30 "$CAND_OUT" "candidate" || cand_rc=$?
qp_teardown

printf 'baseline run rc=%s  candidate run rc=%s\n' "$base_rc" "$cand_rc"
printf '%s\n' "--- baseline replay output ($BASE_OUT) ---"
grep '##KV##' "$BASE_OUT" | sed 's/^.*##KV## //'
printf '%s\n' "--- candidate replay output ($CAND_OUT) ---"
grep '##KV##' "$CAND_OUT" | sed 's/^.*##KV## //'

if ((base_rc != 0 || cand_rc != 0)); then
  t_no "both probes reached ##DONE##" "baseline rc=$base_rc, candidate rc=$cand_rc"
  t_summary
  exit $?
fi

# Guard: without adopted providers there is no replay observation to compare.
cand_adopt="$(printf '%s,%s' \
  "$(grep '##KV## adopt.services=' "$CAND_OUT" | sed 's/.*=//')" \
  "$(grep '##KV## adopt.features=' "$CAND_OUT" | sed 's/.*=//')")"
if [[ $cand_adopt != true,true ]]; then
  t_block "candidate late providers did not adopt; candidate adopt=$cand_adopt"
fi

t_section "probe preconditions"
t_eq "instance label is identical" "$(grep '##KV## instance=' "$BASE_OUT" | sed 's/.*=//')" \
  "$(grep '##KV## instance=' "$CAND_OUT" | sed 's/.*=//')"
for out in "$BASE_OUT" "$CAND_OUT"; do
  t_eq "no probe error in $(basename "$out")" "false" \
    "$(grep -q '##KV## probe.error=' "$out" && printf true || printf false)"
done

t_section "pre-adoption decline/stash/replay unchanged from baseline"
if node "$PILOT_DIR/compare-observations.mjs" "$BASE_OUT" "$CAND_OUT" \
    'decline.' 'replay.' >"$COMPARE_OUT"; then
  t_ok "decline and replay observations are equal" "$(cat "$COMPARE_OUT")"
else
  t_no "decline and replay observations are equal" "$(cat "$COMPARE_OUT")"
fi
printf '%s\n' "--- comparison artifact ($COMPARE_OUT) ---"
cat "$COMPARE_OUT"

t_section "no extra loader turn, ready signal or timer on candidate"
cand() { grep "##KV## $1=" "$CAND_OUT" | sed 's/.*=//'; }
t_eq "facade built no controller before demand" "0" "$(cand decline.appLauncher.constructions)"
t_eq "facade stayed unloaded before demand" "unloaded" "$(cand decline.appLauncher.controller)"
t_eq "replay kept one construction" "0" "$(cand replay.appLauncher.constructions)"
t_eq "decline emitted no transition" "0" "$(cand decline.appLauncher.signals)"
t_eq "replay emitted one ready transition" "1" "$(cand replay.appLauncher.signals)"
t_eq "admitted demand emitted no extra ready signal" "1" "$(cand demand.signals)"
t_eq "admitted demand built exactly one controller" "true" "$(cand demand.controller.built)"
t_eq "controller reached ready" "ready" "$(cand demand.controller.state)"
t_eq "one construction only" "1" "$(cand demand.constructions)"
t_eq "exactly two leases while admitted" "2" "$(cand demand.owners)"
t_eq "release unloaded the controller" "unloaded" "$(cand release.controller.state)"
t_eq "teardown added no construction" "1" "$(cand release.constructions)"
t_eq "facade lease released" "1" "$(cand release.owners.beforeReplayRelease)"
t_eq "unit stopped after all owners released" "stopped" "$(cand release.state.afterAllOwners)"
t_eq "release emitted one stop transition only" "2" "$(cand release.signals)"
t_eq "controller still unloaded after gate teardown" "unloaded" "$(cand release.controller.state.afterAllOwners)"
t_eq "idempotent teardown added no construction" "1" "$(cand release.constructions.afterAllOwners)"

t_section "all four facades decline/stash/replay without a premature controller"
for id in pass audioMixer imageViewer; do
  t_eq "$id declined before adoption" "not_started" "$(cand "decline.$id.state")"
  t_eq "$id stashed one owner" "1" "$(cand "decline.$id.owners")"
  t_eq "$id replayed to ready" "ready" "$(cand "replay.$id.state")"
  t_eq "$id built no controller on replay" "0" "$(cand "replay.$id.constructions")"
  t_eq "$id stayed unloaded on replay" "unloaded" "$(cand "replay.$id.controller")"
done
t_eq "annotation component handed off by the late half" "true" "$(cand adopt.annotationComponent)"
t_eq "bar runtime demand not owned by the late half" "true" "$(cand late.bar.not.owned)"

t_section "every late unit declined and replayed identically"
t_eq "all remaining services/features ids observed" "32" "$(cand late.ids.count)"
t_eq "decline record covers every late id" "true" \
  "$(grep -q '##KV## decline.allLate=' "$CAND_OUT" && printf true || printf false)"
t_eq "replay record covers every late id" "true" \
  "$(grep -q '##KV## replay.allLate=' "$CAND_OUT" && printf true || printf false)"

t_summary
