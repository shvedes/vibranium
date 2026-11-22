#!/bin/bash
# Suite: lyrics-scroll-return - no teleport under a flick; gliding return.
#
# A flick of the fullscreen transcript used to keep scrolling after release and
# then snap to the current cue in a single frame, because the settle timer and
# the cue edge could call _centre() while the view was still moving - and
# _centre()'s row-not-created branch used positionViewAtIndex. This suite pins
# the contract: no placement while moving, the timer re-armed on the real
# movement-end / bounds edges and gated on live moving state, and the return
# driven through the scrollTo NumberAnimation on contentY.
#
# LyricsPane owns real ListView delegates and the offscreen platform has no
# compositor, screens or synthesised input, so the probe reads the real file
# over XHR and evaluates its own handler bodies in a headless object. Actual
# render-loop frame timing and real flick delivery are recorded as a SKIP,
# never a pass.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "lyrics-scroll-return" "no teleport under a flick; gliding return"
require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/lyrics-scroll-return.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "the pane source was read" "slice.source" "true"
qp_assert "every lifted fragment was found" "slice.missing" ""

t_section "source shape: live gate and real edges"
qp_assert "follow gates on live moving state" "shape.followGatesMoving" "true"
qp_assert "settle guard gates on live moving state" "shape.settleGatesMoving" "true"
qp_assert "movement end re-arms the timer" "shape.movementEndRearms" "true"
qp_assert "a bounds edge also re-arms it" "shape.boundsRearm" "true"
qp_assert "the centre path uses scrollTo" "shape.centreGlides" "true"
qp_assert "no row-null instant teleport" "shape.noRowNullTeleport" "true"
qp_assert "scrollTo is the contentY animation" "shape.scrollToIsContentYAnimation" "true"

t_section "no placement while the flick is still moving"
qp_assert "no instant placement mid-flick" "mid.noInstantWhileFlicking" "true"
qp_assert "no animated placement mid-flick" "mid.noAnimatedWhileFlicking" "true"
qp_assert "fresh-sheet cut held until the stop" "mid.freshSheetHeld" "true"

t_section "the return follows the stop edge and glides"
qp_assert "movement end re-arms the timer" "stop.timerRearmedOnMovementEnd" "true"
qp_assert "no one-frame teleport on return" "stop.noTeleport" "true"
qp_assert "the return starts the NumberAnimation" "stop.glideStarted" "true"
qp_assert "the fresh-sheet cut is released" "stop.freshSheetCleared" "true"
qp_assert "the reader's pin is released" "stop.pinReleased" "true"
qp_assert "the target is past the current offset" "stop.targetIsAhead" "true"
qp_assert "the glide has intermediate frames" "stop.hasIntermediateFrame" "true"

t_section "bounds are an arm edge too"
qp_assert "reaching the end re-arms the timer" "bounds.timerRearmed" "true"

t_section "headless limitation"
t_skip "real flick delivery and render-loop frame timing" \
  "offscreen has no compositor, screens or synthesised input; the probe drives the real lifted handlers against a stub view and samples the animation path"

t_summary
