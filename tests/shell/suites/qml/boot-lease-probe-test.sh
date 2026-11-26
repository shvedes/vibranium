#!/bin/bash
# Suite: boot-lease-probe - Phase 4 conditional investigation, headless.
#
# The probe drives the real UnitGate, UnitLease and IpcRouter singletons with a
# synthetic catalog and a stand-in facade. It cannot construct boot/Boot.qml
# headlessly; the shipped registration sites are pinned statically by
# suites/js/boot-lease-contract.test.mjs. Expected wire replies and lease states
# are read from tests/shell/fixtures/boot-lease/*.json, not inlined here, so a
# change in the observed contract shows up as a fixture mismatch.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "boot-lease-probe" "no-change lease contract: four startup moments plus pending/failed/blocked facades"
require_qs

trap qp_teardown EXIT

FIXDIR="$TESTS_SHELL_DIR/fixtures/boot-lease"

# fx <fixture.json> <dotted.key> - print the fixture value in the same shape
# the probe prints it (objects as compact JSON in declaration order).
fx() {
  node -e '
    const fs = require("fs")
    const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const v = process.argv[2].split(".").reduce((a, k) => (a === null || a === undefined ? a : a[k]), o)
    process.stdout.write(v === undefined ? "<missing fixture key>" : (v && typeof v === "object" ? JSON.stringify(v) : String(v)))
  ' "$FIXDIR/$1" "$2"
}

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/boot-lease-audit.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the probe and its stated limitation"
t_eq "the probe ran without throwing" "" "$(qp_get probe.error)"
t_not_empty "the probe reported its limitation" "$(qp_get limitation)"
t_note "$(qp_get limitation)"
t_eq "the shortcut target is the pinned word list" \
  "$(fx moments.json shortcutWords)" "$(qp_get shortcut.words)"

t_section "moment (a): before any request"
t_eq "no registered target" "$(fx moments.json moments.before.registered)" "$(qp_get before.registered)"
t_eq "the unit is unstarted" "$(fx moments.json moments.before.gateState)" "$(qp_get before.gateState)"
t_eq "direct open never reaches a facade" "$(fx moments.json moments.before.open)" "$(qp_get before.open)"
t_eq "the shortcut target never reaches a facade" "$(fx moments.json moments.before.shortcut)" "$(qp_get before.shortcut)"

t_section "moment (b): during provider loading"
t_eq "resolver decline defers and keeps the lease" "$(fx moments.json moments.loading.ensure)" "$(qp_get loading.ensure)"
t_eq "still no registered target" "$(fx moments.json moments.loading.registered)" "$(qp_get loading.registered)"
t_eq "the unit stays unstarted" "$(fx moments.json moments.loading.gateState)" "$(qp_get loading.gateState)"
t_eq "direct open is refused at the router" "$(fx moments.json moments.loading.open)" "$(qp_get loading.open)"
t_eq "the shortcut is refused at the router" "$(fx moments.json moments.loading.shortcut)" "$(qp_get loading.shortcut)"

t_section "moment (c): adopted, facade not constructed"
t_eq "refresh settles the deferred unit" "$(fx moments.json moments.adopted.refresh)" "$(qp_get adopted.refresh)"
t_eq "the unit is ready" "$(fx moments.json moments.adopted.gateState)" "$(qp_get adopted.gateState)"
t_eq "boot releasing its facade lease stops the unit" \
  "$(fx moments.json moments.adopted.stateAfterBootRelease)" "$(qp_get adopted.stateAfterBootRelease)"
t_eq "still no registered target" "$(fx moments.json moments.adopted.registered)" "$(qp_get adopted.registered)"
t_eq "direct open is still refused at the router" "$(fx moments.json moments.adopted.open)" "$(qp_get adopted.open)"
t_eq "the shortcut is still refused at the router" "$(fx moments.json moments.adopted.shortcut)" "$(qp_get adopted.shortcut)"

t_section "moment (d): facade present"
t_eq "the facade registers on completion" "$(fx moments.json moments.facade.registered)" "$(qp_get facade.registered)"
t_eq "direct open succeeds" "$(fx moments.json moments.facade.open)" "$(qp_get facade.open)"
t_eq "the shortcut succeeds" "$(fx moments.json moments.facade.shortcut)" "$(qp_get facade.shortcut)"
t_eq "the lease reaches ready" "$(fx moments.json moments.facade.phase)" "$(qp_get facade.phase)"
t_eq "the gate reaches ready" "$(fx moments.json moments.facade.gateState)" "$(qp_get facade.gateState)"
t_eq "exactly one controller was built" "$(fx moments.json moments.facade.constructions)" "$(qp_get facade.constructions)"

t_section "registered facade, genuinely pending controller"
t_eq "the gate defers with ok=true and a lease" "$(fx facade-pending.json ensure)" "$(qp_get pending.ensure)"
t_eq "the first request is dropped" "$(fx facade-pending.json first)" "$(qp_get pending.first)"
t_eq "the facade phase is unavailable" "$(fx facade-pending.json phase)" "$(qp_get pending.phase)"
t_eq "the facade error names the load path" "$(fx facade-pending.json error)" "$(qp_get pending.error)"
t_eq "the dropped demand built no controller" "$(fx facade-pending.json constructions)" "$(qp_get pending.constructions)"
t_eq "the gate has stopped after the lease was dropped" "$(fx facade-pending.json gateState)" "$(qp_get pending.gateState)"
t_eq "a retry while still pending is dropped too" "$(fx facade-pending.json retry)" "$(qp_get pending.retry)"
t_eq "and the phase is unchanged" "$(fx facade-pending.json retryPhase)" "$(qp_get pending.retry.phase)"
t_eq "only a later demand succeeds" "$(fx facade-pending.json recovered)" "$(qp_get pending.recovered)"
t_eq "that demand reaches ready" "$(fx facade-pending.json recoveredPhase)" "$(qp_get pending.recovered.phase)"
t_eq "after exactly one construction" "$(fx facade-pending.json recoveredConstructions)" "$(qp_get pending.recovered.constructions)"

t_section "registered facade, genuinely blocked unit"
t_eq "ensure reports dependency_blocked" "$(fx facade-blocked.json ensure)" "$(qp_get blocked.ensure)"
t_eq "the wire reply is the same as the pending case" "$(fx facade-blocked.json reply)" "$(qp_get blocked.reply)"
t_eq "the facade phase is unavailable" "$(fx facade-blocked.json phase)" "$(qp_get blocked.phase)"
t_eq "its error is gate, not load" "$(fx facade-blocked.json error)" "$(qp_get blocked.error)"
t_eq "the gate stops after the refused lease" "$(fx facade-blocked.json gateState)" "$(qp_get blocked.gateState)"
t_eq "pending and blocked are wire-indistinguishable" "$(qp_get pending.first)" "$(qp_get blocked.reply)"
t_ne "but their lease errors differ" "$(qp_get pending.error)" "$(qp_get blocked.error)"

t_section "registered facade, genuinely failed controller"
t_eq "a startupError reaches the same wire reply" \
  "$(fx facade-failed.json controllerStartupError.reply)" "$(qp_get failed.reply)"
t_eq "the facade phase is failed" "$(fx facade-failed.json controllerStartupError.phase)" "$(qp_get failed.phase)"
t_eq "the facade error is the controller's message" \
  "$(fx facade-failed.json controllerStartupError.error)" "$(qp_get failed.error)"
t_eq "the unit stops behind the failed demand" \
  "$(fx facade-failed.json controllerStartupError.gateState)" "$(qp_get failed.gateState)"
t_eq "a fresh demand recovers" "$(fx facade-failed.json controllerStartupError.recovered)" "$(qp_get failed.recovered)"
t_eq "and reaches ready" "$(fx facade-failed.json controllerStartupError.recoveredPhase)" "$(qp_get failed.recovered.phase)"

t_section "registered facade, resolver throws"
t_eq "ensure reports failed" "$(fx facade-failed.json resolverThrows.ensure)" "$(qp_get gateFailed.ensure)"
t_eq "the wire reply is unchanged" "$(fx facade-failed.json resolverThrows.reply)" "$(qp_get gateFailed.reply)"
t_eq "the facade phase is failed" "$(fx facade-failed.json resolverThrows.phase)" "$(qp_get gateFailed.phase)"
t_eq "the facade error names the unit" "$(fx facade-failed.json resolverThrows.error)" "$(qp_get gateFailed.error)"

t_note "the reproduced pending/drop path needs a registered dispatch; the four moments show the shipped launcher has none in that window"
t_summary
