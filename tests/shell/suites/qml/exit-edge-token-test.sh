#!/bin/bash
# Suite: APP-3 / APP-6 - exit fallback token and OSD live fade edge.
#
# The real Notifications and OSD singletons cannot be constructed offscreen,
# so the probe (suites/qml/probes/exit-edge-token.qml) evaluates their OWN
# function and handler bodies in a headless QtObject with stubbed timers. It
# pins the state transitions, not just the final values: the fallback drops
# only its armed entry, the card's live edge clears and disarms it, and the
# OSD surface is retained by the card's opacity edge with the timer as ceiling.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "exit-edge-token" "notification fallback token and OSD live fade edge"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/exit-edge-token.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

NOTIF="$SHELL_DIR/features/notifications/Notifications.qml"
OSD="$SHELL_DIR/features/osd/OSD.qml"
CARD="$SHELL_DIR/features/osd/OSDCard.qml"

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "the notification source was read" "slice.notifSource" "true"
qp_assert "the OSD source was read" "slice.osdSource" "true"
qp_assert "the card source was read" "slice.cardSource" "true"
qp_assert "every notification function under test was found" "notif.missing" ""
qp_assert "the fallback onTriggered body was found" "notif.fireFound" "true"
qp_assert "every OSD function under test was found" "osd.missing" ""
qp_assert "the exitTimer onTriggered body was found" "osd.fireFound" "true"
qp_assert "the funnel was instrumented with a call counter" "osd.keepInstrumented" "true"
qp_assert "the card's onOpacityChanged body was found" "osd.cardHandlerFound" "true"

t_section "APP-3: the armed entry, not the leaving set"
qp_assert "_release records the armed entry" "notif.release.setsFallbackToA" "true"
qp_assert "the first release arms the ceiling" "notif.release.armedTimer" "true"
qp_assert "a second release does not steal the token" "notif.release.keepsFallbackA" "true"
qp_assert "and does not re-arm the ceiling" "notif.release.noRearm" "true"
qp_assert "the ceiling drops the armed entry" "notif.fire.droppedA" "true"
qp_assert "but keeps the late-arriving card" "notif.fire.keptB" "true"
qp_assert "exactly one card left the pile" "notif.fire.count" "1"

t_section "APP-3: the live fade edge clears and disarms"
qp_assert "the armed entry was c before the edge" "notif.edge.armedC" "true"
qp_assert "the card's edge drops its own entry" "notif.edge.droppedC" "true"
qp_assert "and keeps the other leaving card" "notif.edge.keptD" "true"
qp_assert "the armed token is cleared" "notif.edge.clearedFallback" "true"
qp_assert "the ceiling is stopped" "notif.edge.stoppedTimer" "true"
qp_assert "a late ceiling cannot sweep the survivor" "notif.edge.lateFireKeptD" "true"

t_section "APP-6: retention follows the card's live opacity edge"
qp_assert "hide arms the exit ceiling" "osd.hide.armedCeiling" "true"
qp_assert "and starts the fade" "osd.hide.dismissing" "true"
qp_assert "but does not linger yet" "osd.hide.notLingeringYet" "true"
qp_assert "the card's edge retains the surface" "osd.edge.keepCalled" "true"
qp_assert "and clears dismissing" "osd.edge.dismissingCleared" "true"
qp_assert "and starts the linger window" "osd.edge.lingering" "true"
qp_assert "exactly once" "osd.edge.lingerRestarted" "true"
qp_assert "the ceiling is disarmed by the edge" "osd.edge.ceilingDisarmed" "true"
qp_assert "retention never relied on firing the timer" "osd.edge.noTimerFired" "true"

t_section "APP-6: the ceiling and the lock guard still hold"
qp_assert "a never-published card is retained by the timer" "osd.ceiling.keepCalled" "true"
qp_assert "the ceiling clears dismissing" "osd.ceiling.dismissingCleared" "true"
qp_assert "and starts the linger window" "osd.ceiling.lingering" "true"
qp_assert "a suppressed desktop never lingers" "osd.suppressed.noLinger" "true"

t_section "the source still says what the probe measured"
t_contains "the fallback drops only its armed entry" \
  "root._dropLeaving(root._fallbackEntry)" "$(<"$NOTIF")"
t_contains "the fallback is guarded on an armed entry" \
  "if (root._fallbackEntry)" "$(<"$NOTIF")"
t_not_contains "no timer calls _dropLeaving argument-less" \
  "onTriggered: root._dropLeaving()" "$(<"$NOTIF")"
t_contains "noteExitDone is the live fade edge" \
  "function noteExitDone(entry)" "$(<"$NOTIF")"
t_contains "the ceiling is a labelled fallback, not the drop trigger" \
  "exitFallbackMs" "$(<"$NOTIF")"
t_contains "the card publishes its live fade completion" \
  "onOpacityChanged" "$(<"$CARD")"
t_contains "the card reads its own live opacity" \
  "!OSD.visible && root.opacity <= 0.02" "$(<"$CARD")"
t_contains "the card calls the one keep-surface funnel" \
  "OSD._keepSurface()" "$(<"$CARD")"
keep_body="$(sed -n '/function _keepSurface/,/^  }/p' "$OSD")"
if printf '%s' "$keep_body" | grep -qF 'exitTimer.stop()'; then
  t_ok "the OSD funnel stops the exit ceiling"
else
  t_no "the OSD funnel stops the exit ceiling" "the _keepSurface body does not stop exitTimer"
fi
t_contains "the exit timer is the labelled fallback" \
  "id: exitTimer" "$(<"$OSD")"
t_contains "and it calls the same funnel" \
  "onTriggered: root._keepSurface()" "$(<"$OSD")"

t_summary
