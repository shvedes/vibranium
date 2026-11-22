#!/bin/bash
# Suite: power-menu reset/dispatch epochs and the query's single source.
#
# OVL-7: PowerMenu.reset() was queued on the visible-false edge, so a close and
# a reopen inside one turn let the old reset wipe the new session's query.
# OVL-8: activate()/confirmPending() dismissed first and deferred the dispatch
# with no generation, so two open+activate pairs before the drain ran two
# actions. The epoch retires the older intent but must be untouched by the
# dismiss close() of the same activation.
# OVL-9: PowerMenu.query and searchField.text were two copied stores; five
# imperative resyncs in the panel did not emit edited(), so the field and the
# filtered results disagreed. The query is the source and InputField.value is
# its one guarded bridge into the control.
#
# PowerMenu is a Singleton that owns a live overlay, and Session.dispatch can
# end a session, so the probe evaluates the real function bodies with stubbed
# Session/Bus/SurfaceClaim/MenuLib edges. Each Qt.callLater is observed on the
# next pumped turn, not just by its final value.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "power-menu" "reset and dispatch epochs, one query source"
require_qs

trap qp_teardown EXIT

export POWERMENU_SRC="$(cat "$SHELL_DIR/features/powerMenu/PowerMenu.qml")"
export PANEL_SRC="$(cat "$SHELL_DIR/features/powerMenu/PowerMenuPanel.qml")"
export INPUTFIELD_SRC="$(cat "$SHELL_DIR/common/ui/InputField.qml")"

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/power-menu.qml" 25; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
else
  t_ok "the probe reached ##DONE##"
fi

t_section "the source slice"
t_eq "the probe ran without throwing" "" "$(qp_get drive.error)"
t_eq "no function body was left behind" "" "$(qp_get slice.missing)"
t_eq "all three sources reached the probe" "true" "$(qp_get source.loaded)"

t_section "OVL-7: reset lands with the close, not a later turn"
t_eq "the query is already clear in the closing turn" "true" \
  "$(qp_get reset.inCloseTurn)"
t_eq "the reopened session keeps its own query before the drain" "true" \
  "$(qp_get reset.beforeDrain)"
t_eq "and still keeps it after the old callLater would have fired" "true" \
  "$(qp_get reset.afterDrain)"

t_section "OVL-8: a newer intent retires an older dispatch"
t_eq "only the newest activation dispatches" "beta" \
  "$(qp_get dispatch.stale)"
t_eq "the one honest activation is not cancelled by its own close" "alpha" \
  "$(qp_get dispatch.single)"
t_eq "the confirm path still dispatches after dismissal" "poweroff" \
  "$(qp_get confirm.single)"
t_eq "no confirmation survives a newer intent" "" \
  "$(qp_get confirm.stale)"

t_section "OVL-8: the destructive-family gate is untouched"
t_eq "_execute refuses a destructive row" "confirmation_required" \
  "$(qp_get gate.fault)"
t_eq "and nothing reaches Session.dispatch" "true" \
  "$(qp_get gate.noDispatch)"

t_section "OVL-9: one guarded bridge, no imperative resync"
t_eq "InputField exposes value" "true" "$(qp_get bridge.hasValue)"
t_eq "binding value is accepted" "true" "$(qp_get bridge.bindAccepted)"
t_eq "a source write lands in the control" "true" "$(qp_get bridge.sourceToField)"
t_eq "and emits no edited" "true" "$(qp_get bridge.noEditOnSourceWrite)"
t_eq "a user edit still writes the source" "true" "$(qp_get bridge.editWritesSource)"
t_eq "with exactly one edited" "1" "$(qp_get bridge.editCount)"
t_eq "the declaration exists" "true" "$(qp_get input.valueProperty)"
t_eq "the guarded handler exists" "true" "$(qp_get input.valueHandler)"
t_eq "it writes input.text under an equality guard" "true" \
  "$(qp_get input.guardedWrite)"
t_eq "and does not emit edited from the bridge" "true" \
  "$(qp_get input.noEditedInBridge)"
t_eq "the panel keeps no imperative field copy" "0" "$(qp_get panel.fieldWrites)"
t_eq "the panel binds value to the query" "true" "$(qp_get panel.valueBinding)"

t_section "OVL-13: the row latch and the stale focus callback"
latch_decl="$(grep -n -B6 'property bool _rowsPending' <<<"$PANEL_SRC")"
if grep -q 'onResultsChanged' <<<"$latch_decl"; then
  t_ok "the row latch is labelled with its re-entrant source"
else
  t_no "the row latch is labelled with its re-entrant source" \
    "no onResultsChanged comment precedes _rowsPending"
fi
if grep -q 'g !== panel._swapGen' <<<"$PANEL_SRC"; then
  t_ok "the focus deferral retires a superseded swap"
else
  t_no "the focus deferral retires a superseded swap" \
    "the deferred reassert does not check the captured swap generation"
fi

t_summary
