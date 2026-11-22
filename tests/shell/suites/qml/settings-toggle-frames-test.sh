#!/bin/bash
# Suite: settings-toggle-frames - one toggle seen on consecutive frames.
#
# Two findings share this probe. SET-1: menuPages() signs its cache on the
# deferred rev, so a menu built in the toggle's own turn shows stale rows.
# SET-2: statusbarPosition reads the flush-owned raw map, so it disagrees with
# the shard-backed option until the flush echo lands.
#
# The probe drives the real Settings singleton and samples the same synchronous
# turn, then the next one. Private XDG roots keep the toggle's file write off
# the session's real settings.json. The source half checks the two mechanics
# against the real file handed to the probe, so a different fix cannot pass on
# the frame assertions alone.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "settings-toggle-frames" "a toggle rebuilds its menu and reads live before flush"
require_qs

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-settings-frames.XXXXXX")"
mkdir -p "$WORK/config" "$WORK/state" "$WORK/cache" "$WORK/data" "$WORK/run"
export XDG_CONFIG_HOME="$WORK/config" XDG_STATE_HOME="$WORK/state"
export XDG_CACHE_HOME="$WORK/cache" XDG_DATA_HOME="$WORK/data"
export VIBRANIUM_RUNTIME="$WORK/run"
export VIBRANIUM="$VIBRANIUM_DIR"

cleanup() {
  qp_teardown
  [[ -n ${WORK:-} && -d $WORK ]] && rm -rf "$WORK"
}
trap cleanup EXIT

SETTINGS_SRC="$(cat "$SHELL_DIR/common/settings/Settings.qml")"
export SETTINGS_SRC

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/settings-toggle-frames.qml" 25; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
else
  t_ok "the probe reached ##DONE##"
fi

t_section "the toggle, sampled in one turn"
t_eq "the toggle was accepted" "true" "$(qp_get toggle.accepted)"
t_eq "the baseline is the old position" "top" "$(qp_get same.baselineStatus)"
t_eq "the shard-backed value is already new" "true" "$(qp_get same.valueIsNew)"
t_eq "values identity changes synchronously" "true" "$(qp_get same.valuesIdentityChanged)"
t_eq "menuPages() rebuilds in the SAME turn" "true" "$(qp_get same.menuPagesRebuilt)"
t_eq "statusbarPosition agrees with value() before flush" "true" "$(qp_get same.statusAgreesWithValue)"
t_eq "rev is still the previous generation (deferred)" "true" "$(qp_get same.revStillDeferred)"

t_section "the next turn"
t_eq "the deferred rev bump lands" "true" "$(qp_get post.revBumped)"
t_eq "statusbarPosition settles on the new value" "true" "$(qp_get post.statusSettled)"

t_section "mechanism (source under test)"
t_eq "the probe received Settings.qml" "true" "$(qp_get src.settled)"
t_eq "the menu cache signs on values, not rev" "true" "$(qp_get src.menuSignsOnValues)"
t_eq "the menu cache signs on the misc values map" "true" "$(qp_get src.menuSignsOnMiscMap)"
t_eq "statusbarPosition derives from value()" "true" "$(qp_get src.statusReadsValue)"
t_eq "statusbarPosition no longer reads the raw map" "true" "$(qp_get src.statusNoRawRead)"

t_summary
