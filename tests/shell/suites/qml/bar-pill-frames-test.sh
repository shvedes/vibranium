#!/bin/bash
# Suite: bar-pill-frames - one clock per bar pill, one source for the cycle row.
#
# The wheel cycle derives the painted row from a single cycle progress and a
# source row instead of keeping a third copy that three handlers write. The
# battery and now-playing pills each drive their width from one animated
# value instead of fighting a width Behavior against that value's own Glide.
# The frame half samples consecutive turns; the source half checks the two
# real files (handed to the probe through the environment) so a copy of the
# shape cannot keep this suite green after the modules drift.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "bar-pill-frames" "one clock per bar pill, one source for the cycle row"
require_qs

# Private XDG roots: the cycle land writes shell.battery.device through
# Settings.setRawSection. The verdicts do not depend on the session's real
# pick, and this keeps the run from writing it.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-bar-pill.XXXXXX")"
mkdir -p "$WORK/config" "$WORK/state" "$WORK/cache" "$WORK/data" "$WORK/run"
export XDG_CONFIG_HOME="$WORK/config" XDG_STATE_HOME="$WORK/state"
export XDG_CACHE_HOME="$WORK/cache" XDG_DATA_HOME="$WORK/data"
export VIBRANIUM_RUNTIME="$WORK/run"
cleanup() {
  qp_teardown
  [[ -n ${WORK:-} && -d $WORK ]] && rm -rf "$WORK"
}
trap cleanup EXIT

# The two real files, handed to the probe so the source assertions cannot go
# stale when the modules change.
BAR_BATTERY_SRC="$(cat "$SHELL_DIR/features/bar/modules/Battery/Battery.qml")"
export BAR_BATTERY_SRC
BAR_NOWPLAYING_SRC="$(cat "$SHELL_DIR/features/bar/modules/NowPlaying/NowPlaying.qml")"
export BAR_NOWPLAYING_SRC

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/bar-pill-frames.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
else
  t_ok "the probe reached ##DONE##"
fi

t_section "frame contract"

t_eq "the outgoing row is painted before the midpoint" "dev-a" "$(qp_get cycle.beforeMid)"
t_eq "the landed row is painted at the midpoint" "dev-b" "$(qp_get cycle.atMid)"
t_eq "the landed row stays after the midpoint" "dev-b" "$(qp_get cycle.afterMid)"
t_eq "a fast second wheel starts from the landed row" "dev-b" "$(qp_get cycle.secondFrom)"
t_eq "the second wheel lands at its midpoint" "dev-c" "$(qp_get cycle.secondAtMid)"

t_eq "width equals its one binding every frame" "0" "$(qp_get width.lagFrames)"
t_eq "width never takes a correction frame" "0" "$(qp_get width.nonMonotone)"

t_section "battery module source"

t_eq "the probe received Battery.qml" "true" "$(qp_get src.batteryPresent)"
t_eq "no second clock on pill.width" "true" "$(qp_get src.batteryNoWidthBehavior)"
t_eq "cycleK is driven by the existing animation" "true" "$(qp_get src.batteryCycleKDriven)"
t_eq "cycleFromRow has one writer (the wheel)" "true" "$(qp_get src.batteryCycleFromOnce)"
t_eq "paintRow is derived, not written by handlers" "true" "$(qp_get src.batteryNoPaintWrites)"
t_eq "shownRow derives from cycleK at the midpoint" "true" "$(qp_get src.batteryMidDerivation)"
t_eq "the ScriptAction cycle breaker is kept" "true" "$(qp_get src.batteryBreakerKept)"
t_eq "the device pick is still written at the land edge" "true" "$(qp_get src.batteryLandWriteKept)"
t_eq "the fullscreen deferral is kept" "true" "$(qp_get src.batteryFlashGateKept)"

t_section "now-playing module source"

t_eq "the probe received NowPlaying.qml" "true" "$(qp_get src.npPresent)"
t_eq "no second clock on pill.width" "true" "$(qp_get src.npNoWidthBehavior)"
t_eq "the name swap is a scalar in the width expression" "true" "$(qp_get src.npNameScalar)"
t_eq "the label still reads the live title" "true" "$(qp_get src.npLiveTitle)"
t_eq "the name kick reads the live title" "true" "$(qp_get src.npKickLiveTitle)"

t_summary
