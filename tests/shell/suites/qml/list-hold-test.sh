#!/bin/bash
# Suite: list-hold - a held key keeps the bar centred while rows slide.
#
# A repeat step re-arms the content ease before the last one lands. A direct
# content write teleports a row in one frame, and a long ease makes the cursor
# trail the bar; a bar pinned to a screen slot then snaps at the clamp boundary
# where the view can no longer centre the row. The fix rides one short linear
# leg on both the content and the bar. This suite drives a real event loop with
# repeat steps and reads the running bar off highlightItem, so it asserts the
# geometry the eye sees rather than the internals that produce it.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "list-hold" "held-key centre lock: a pinned bar and sliding rows"

require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/list-hold.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"

t_section "the bar holds the viewport centre through the hold"
qp_assert "a repeat step takes the short leg" hold.legArmed true
qp_assert "the bar does not drift on screen" hold.barPinned true
t_note "bar screen spread: $(qp_get hold.barSpread)px"

t_section "rows slide; no one-frame full-row teleport"
qp_assert "a frame moves less than one row" hold.noTeleport true
# The probe reads the centre at the landing edge of each short leg, not on a
# fixed timer turn: a read two turns after a step races the 30ms leg against
# the 16ms timer and can catch the row half a row short of centre. A count
# guard keeps the centre assertion from passing with no landed leg sampled.
qp_assert "every short leg was measured at its landing edge" hold.samples 10
qp_assert "the cursor stays near the centre" hold.centred true
qp_assert "the row is the 48px fixture the step is measured against" hold.rowH 48
# A whole-row cut lands on an integer pixel count; an eased leg lands on a
# fractional one. The probe counts fractional steps from the raw frames: a
# printed one-decimal "30" can hide a 30.04px frame under load, so checking
# the string for a decimal point made a legitimate eased leg flake.
t_true "each frame is a positive, fractional, sub-row step" \
  awk -v s="$(qp_get hold.maxFrameStep)" -v r="$(qp_get hold.rowH)" \
  -v f="$(qp_get hold.fractionalFrames)" \
  'BEGIN { exit !(s > 0 && s < r && f > 0) }'
t_note "max frame step $(qp_get hold.maxFrameStep)px against row $(qp_get hold.rowH)px; centre offset $(qp_get hold.maxCentreOffset)px"

t_section "the hold lands and releases cleanly"
qp_assert "the short leg is spent after the hold" after.legSpent true
qp_assert "the view lands on the centred row" after.landed true
qp_assert "dropping the pin takes no bar step" after.barOnRow true

t_section "a wrap keeps its own pace"
qp_assert "a wrap takes no short leg" wrap.noLeg true
qp_assert "the wrap lands on the first row" wrap.toFirst true
qp_assert "the wrap is length-paced, not a short repeat leg" wrap.lengthPaced true

t_summary
