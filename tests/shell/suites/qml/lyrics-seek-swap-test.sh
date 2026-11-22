#!/bin/bash
# Suite: lyrics-seek-swap - one seek commit path and swap opacity restoration.
#
# APP-4: seekAt, seekTo, drag release and wheel must all funnel through one
# commitSeek (clamp, one position/shownPosition write, one notify, one drag
# release); scrubTo remains the only preview writer of shownPosition.
#
# APP-5: the track-swap animation owns one scalar, lyricsSide.opacity is derived
# from it, and closing mid-swap resets it so reopening the SAME track cannot
# bring the transcript back dim.
#
# LyricsFullscreenOverlay cannot be constructed offscreen (it owns a Window,
# four MultiEffect passes and pointer/wheel handlers, and offscreen has no
# compositor, no screens and no synthesised input). The probe therefore reads
# the real file over XHR and evaluates its own handler bodies in a headless
# QtObject. The pointer/wheel *delivery* and the real animation timing are not
# asserted here; the routing and the restored state after a same-track reopen
# are. This limit is recorded as a SKIP, never a pass.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "lyrics-seek-swap" "one seek commit path and swap opacity restoration"
require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/lyrics-seek-swap.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "the overlay source was read" "slice.source" "true"

t_section "APP-4: one commit path"
qp_assert "commitSeek exists" "p4.commitFound" "true"
qp_assert "seekAt was lifted" "p4.seekAtFound" "true"
qp_assert "seekTo was lifted" "p4.seekToFound" "true"
qp_assert "scrubTo was lifted" "p4.scrubFound" "true"
qp_assert "drag release was lifted" "p4.releaseFound" "true"
qp_assert "wheel was lifted" "p4.wheelFound" "true"
qp_assert "all four routes call commitSeek" "p4.allRoutesThroughCommit" "true"
qp_assert "no route commits a position itself" "p4.noDirectPositionWrite" "true"
qp_assert "commitSeek clamps" "p4.commitClamps" "true"
qp_assert "commitSeek clears the drag" "p4.commitClearsSeeking" "true"
qp_assert "commitSeek notifies once" "p4.commitSingleNotify" "true"
qp_assert "commitSeek writes the shown lane once" "p4.commitSingleShownWrite" "true"
qp_assert "scrubTo only previews the lane" "p4.scrubOnlyPreview" "true"
qp_assert "every commit fragment was found" "p4.missing" ""

t_section "APP-4: each route commits exactly once"
qp_assert "seekAt commits once" "p4.seekAt.calls" "1"
qp_assert "seekAt notifies once" "p4.seekAt.notify" "1"
qp_assert "seekAt clamps to its lane fraction" "p4.seekAt.position" "25"
qp_assert "seekAt paints what it wrote" "p4.seekAt.shown" "25"
qp_assert "seekAt releases the drag" "p4.seekAt.seeking" "false"
qp_assert "seekTo commits once" "p4.seekTo.calls" "1"
qp_assert "seekTo notifies once" "p4.seekTo.notify" "1"
qp_assert "seekTo uses its seconds" "p4.seekTo.position" "42"
qp_assert "seekTo paints what it wrote" "p4.seekTo.shown" "42"
qp_assert "seekTo releases the drag" "p4.seekTo.seeking" "false"
qp_assert "drag release commits once" "p4.release.calls" "1"
qp_assert "drag release notifies once" "p4.release.notify" "1"
qp_assert "drag release commits the preview" "p4.release.position" "33"
qp_assert "drag release paints what it wrote" "p4.release.shown" "33"
qp_assert "drag release clears the drag" "p4.release.seeking" "false"
qp_assert "wheel commits once" "p4.wheel.calls" "1"
qp_assert "wheel notifies once" "p4.wheel.notify" "1"
qp_assert "wheel steps from the shown lane" "p4.wheel.position" "5"
qp_assert "wheel paints what it wrote" "p4.wheel.shown" "5"
qp_assert "wheel leaves no drag held" "p4.wheel.seeking" "false"
qp_assert "scrub never commits" "p4.scrub.calls" "0"
qp_assert "scrub never notifies" "p4.scrub.notify" "0"
qp_assert "scrub leaves the player alone" "p4.scrub.position" "0"
qp_assert "scrub moves only the lane" "p4.scrub.shown" "50"

t_section "APP-5: derived opacity, one swap scalar"
qp_assert "the swap script was lifted" "swap.scriptFound" "true"
qp_assert "the opened handler was lifted" "swap.openedFound" "true"
qp_assert "the trackKey handler was lifted" "swap.trackKeyFound" "true"
qp_assert "opacity is derived from the swap scalar" "swap.opacityBound" "true"
qp_assert "the swap owns one scalar" "swap.kScalar" "true"
qp_assert "the script drives the scalar, not the item" "swap.scriptDerived" "true"
qp_assert "closing stops the swap" "swap.stopOnClose" "true"
qp_assert "all four effects still follow lyricsSide" "swap.effectsFollowLyrics" "true"
qp_assert "every swap fragment was found" "swap.missing" ""

t_section "APP-5: same-track reopen restores the transcript"
qp_assert "an open surface shows the transcript" "swap.open.opacity" "1"
qp_assert "a track swap clears it" "swap.mid.opacity" "0"
qp_assert "the track change armed one swap" "swap.mid.restarts" "1"
qp_assert "closing mid-swap stops the animation" "swap.close.stops" "1"
qp_assert "closing resets the scalar" "swap.close.swapK" "1"
qp_assert "reopening the same track restores opacity" "swap.reopen.opacity" "1"
qp_assert "no second swap was armed on reopen" "swap.reopen.restarts" "1"

t_section "headless limitation"
t_skip "real pointer/wheel delivery and MultiEffect swap timing" \
  "offscreen has no compositor, no screens and no synthesised input; the probe drives the real lifted handler bodies in a headless object"

t_summary
