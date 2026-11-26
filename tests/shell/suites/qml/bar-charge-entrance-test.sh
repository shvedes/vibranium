#!/bin/bash
# Suite: bar-charge-entrance - one charge session seed, one module-release edge.
#
# BAR-8: the charging announcement has one seed and one session counter. The
# boot snapshot is never announced, one plug-in speaks for its whole session,
# and "announced" is a comparison against that session rather than a boolean
# copied by two observers. The model drives the seed on either signal; the
# source half checks the two real files.
#
# BAR-12: the modules' entrance release has one writer. It follows the strip's
# slide completion (or lands with the strip when motion is off) instead of a
# second writer on a PauseAnimation.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "bar-charge-entrance" "one charge session seed, one module-release edge"
require_qs
trap qp_teardown EXIT

# The two real files, handed to the probe so the source assertions cannot go
# stale when the modules change.
BAR_BATTERY_SRC="$(cat "$SHELL_DIR/features/bar/modules/Battery/Battery.qml")"
export BAR_BATTERY_SRC
BAR_BAR_SRC="$(cat "$SHELL_DIR/features/bar/BarRuntime.qml")"
export BAR_BAR_SRC

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/bar-charge-entrance.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
else
  t_ok "the probe reached ##DONE##"
fi

t_section "charge session model"

t_eq "one announcement per plug-in" "Charging;Charged;Fully charged;" "$(qp_get charge.rowsFirst)"
t_eq "the seed signal does not change the sequence" "$(qp_get charge.rowsFirst)" "$(qp_get charge.acFirst)"
t_eq "three plug sessions were counted" "3" "$(qp_get charge.sessions)"
t_eq "a boot on AC announces nothing" "" "$(qp_get charge.bootOnAc)"

t_section "entrance gate model"

t_eq "motion on holds modules until the slide lands" "false" "$(qp_get gate.motionBeforeSlide)"
t_eq "slide completion releases the modules" "true" "$(qp_get gate.motionAfterSlide)"
t_eq "no motion releases with the strip" "true" "$(qp_get gate.noMotion)"

t_section "battery module source"

t_eq "the probe received Battery.qml" "true" "$(qp_get src.batteryPresent)"
t_eq "one seed, no split AC/power flags" "true" "$(qp_get src.batterySingleSeed)"
t_eq "announced is derived from the session id" "true" "$(qp_get src.batteryAnnouncedDerived)"
t_eq "the session id has one bump site" "true" "$(qp_get src.batteryOneSessionBump)"
t_eq "announceKind is derived, never written" "true" "$(qp_get src.batteryAnnounceKindDerived)"
t_eq "both signals route to one observer" "true" "$(qp_get src.batteryOneObserver)"
t_eq "onCompleted only calls the observer" "true" "$(qp_get src.batteryCompletedOnlySeeds)"
t_eq "the fullscreen deferral is kept" "true" "$(qp_get src.batteryFlashGateKept)"

t_section "bar source"

t_eq "the probe received Bar.qml" "true" "$(qp_get src.barPresent)"
t_eq "module readiness is derived from the slide edge" "true" "$(qp_get src.barEntranceDerived)"
t_eq "no handler writes module readiness" "true" "$(qp_get src.barNoEntranceWrites)"
t_eq "the slide edge has one writer" "true" "$(qp_get src.barSlideDoneOneWriter)"
t_eq "the duplicate PauseAnimation is gone" "true" "$(qp_get src.barNoPause)"
t_eq "the boot milestones and warm opacity are kept" "true" "$(qp_get src.barBootContractKept)"

t_summary
