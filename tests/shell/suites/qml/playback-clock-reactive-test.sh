#!/bin/bash
# Suite: playback-clock-reactive - sample the live position frame by frame.
#
# Complements the source suite of the same name: it drives the REAL
# PlaybackClock and the real shownPosition binding lifted from the player view.
# Every held frame advances the source and compares the displayed value in that
# frame, so a snapshot that lags or a poll that misses a cue fails the sample,
# not just the final number.
#
# The windows and pointer handlers still cannot be constructed offscreen, so a
# headless stub player stands in for MprisPlayer. That limit is a SKIP, never a
# pass.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "playback-clock-reactive" "one live position, sampled on every frame"
require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/playback-clock-reactive.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "the overlay source was read" "slice.source" "true"
qp_assert "the shown binding was built" "slice.built" "true"
qp_assert "the binding reads the live player, not a copy" "slice.live" "true"

t_section "the clock ticks only while held"
qp_assert "nothing ticks before a holder arrives" "clock.idleBefore" "0"
qp_assert "the held clock keeps ticking" "clock.held.gt5" "true"
qp_assert "the sample set is non-vacuous" "clock.samples.gt5" "true"
qp_assert "no tick shows a stale position" "clock.maxError.zero" "true"
qp_assert "the last release stops the tick" "clock.idleAfter" "0"

t_section "the lane derives in every position state"
qp_assert "an idle lane reads the live player" "derived.idle" "41.2"
qp_assert "a drag owns the lane through the preview" "derived.preview" "12.5"
qp_assert "release hands the lane back to the player" "derived.release" "90"

t_section "headless limitation"
t_skip "real MprisPlayer notify timing and pointer delivery" \
  "offscreen has no compositor and no synthesised input; the probe drives the real clock and the real lifted binding against a stub player"

t_summary
