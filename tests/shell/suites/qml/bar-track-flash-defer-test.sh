#!/bin/bash
# Suite: bar-track-flash-defer - the track flash parks its last event while
# fullscreen.
#
# A next/prev while a fullscreen window owns the screen parks the flash event
# instead of expanding the bar under it. A burst parks one event - the last -
# and replay drops it if its track key is no longer active. The model drives a
# burst, an in-flight cut-off, a disabled flash and a stale token; the source
# half checks the two real files handed to the probe through the environment.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "bar-track-flash-defer" "the track flash parks its last event while fullscreen"
require_qs
trap qp_teardown EXIT

BAR_NOWPLAYING_SRC="$(cat "$SHELL_DIR/features/bar/modules/NowPlaying/NowPlaying.qml")"
export BAR_NOWPLAYING_SRC
BAR_BAR_SRC="$(cat "$SHELL_DIR/features/bar/BarRuntime.qml")"
export BAR_BAR_SRC

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/bar-track-flash-defer.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
else
  t_ok "the probe reached ##DONE##"
fi

t_section "defer model"

t_eq "a plain track change flashes immediately" "true" "$(qp_get model.plainFlash)"
t_eq "no flash while fullscreen" "false" "$(qp_get model.activeInFullscreen)"
t_eq "no flash started during the burst" "0" "$(qp_get model.startsInFullscreen)"
t_eq "one event is held during the burst" "true" "$(qp_get model.heldInFullscreen)"
t_eq "the held event is the last track" "C" "$(qp_get model.heldKey)"
t_eq "the flash replays on exit" "true" "$(qp_get model.activeAfterExit)"
t_eq "the burst replays once" "1" "$(qp_get model.startsAfterExit)"
t_eq "the held event is consumed" "true" "$(qp_get model.heldAfterExit)"
t_eq "the replay reveals the last track" "C" "$(qp_get model.titleAfterExit)"
t_eq "an in-flight flash is parked as an event" "true" "$(qp_get model.parkedInFlight)"
t_eq "the parked event replays once" "2" "$(qp_get model.startsAfterParkReplay)"
t_eq "a disabled flash parks nothing" "true" "$(qp_get model.disabledDoesNotPark)"
t_eq "a stale held key is dropped on exit" "true" "$(qp_get model.staleTokenDropped)"

t_section "module source"

t_eq "the probe received NowPlaying.qml" "true" "$(qp_get src.npPresent)"
t_eq "one writer holds the event, pending is derived" "true" "$(qp_get src.npHeldEvent)"
t_eq "the fire gate parks the event and replays" "true" "$(qp_get src.npFireGate)"
t_eq "track changes and IPC share the gate" "true" "$(qp_get src.npBothRoutesDefer)"
t_eq "replay consumes and validates the held key" "true" "$(qp_get src.npReplayToken)"
t_eq "lost track and disabled flash drop the event" "true" "$(qp_get src.npInvalidations)"
t_eq "the replay reads the live title" "true" "$(qp_get src.npLiveTitle)"
t_eq "the reveal clock is shared and active is derived" "true" "$(qp_get src.npSharedReveal)"
t_eq "the transport glyph and its dwell have one writer" "true" "$(qp_get src.npOneTransportWriter)"

t_section "bar source"

t_eq "the IPC result reports fullscreen deferral" "true" "$(qp_get src.barDefer)"

t_summary
