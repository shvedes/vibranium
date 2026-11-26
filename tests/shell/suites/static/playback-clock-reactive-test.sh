#!/bin/bash
# Suite: playback-clock-reactive - position is derived, never copied.
#
# The reactive-design invariants this pins:
#   one writer per value  - no surface writes its shown position; the player
#                           owns that value and the preview owns only itself.
#   derive, do not copy   - every surface reads a binding on the live player.
#   one clock at source   - one refcounted driver, no per-surface timer.
#
# The driver is a Timer because an interpolated DBus value must advance while
# no window is rendering; a FrameAnimation stalled at the opening frame. No
# surface gets a second driver and no duration is copied out of this one.
#
# SOURCE suite: the clock is a singleton and the surfaces own windows and
# pointer handlers, so no headless construction can observe their bindings.
# The live tick and drift assertions are in the QML suite of the same name;
# this suite pins the ownership shape they need.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "playback-clock-reactive" "one live position, derived by every surface"

CLOCK="$SHELL_DIR/common/state/PlaybackClock.qml"
OVERLAY="$SHELL_DIR/features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml"
ISLAND="$SHELL_DIR/features/bar/modules/NowPlaying/NowPlayingIsland.qml"
LOCK="$SHELL_DIR/features/lock/NowPlaying.qml"
t_file "the shared clock source exists" "$CLOCK"
t_file "the player view source exists" "$OVERLAY"
t_file "the bar island source exists" "$ISLAND"
t_file "the lock source exists" "$LOCK"
CLK="$(<"$CLOCK")"
OV_SRC="$(<"$OVERLAY")"
IS_SRC="$(<"$ISLAND")"
LK_SRC="$(<"$LOCK")"

t_section "one driver, one interval, one idle gate"
t_contains "the clock owns one timer" "Timer {" "$CLK"
t_contains "the timer runs only while held" "running: root.ticking" "$CLK"
t_contains "the timer emits the one tick" "onTriggered: root.tick()" "$CLK"
t_contains "the tick is one signal" "signal tick()" "$CLK"
t_not_match "no frame animation is wired" 'FrameAnimation \{' "$CLK"
t_contains "the cadence is published once" "readonly property int tickMs: 100" "$CLK"
t_contains "the timer reads that cadence" "interval: root.tickMs" "$CLK"
t_contains "a re-acquired clock ticks at once" "triggeredOnStart: true" "$CLK"
t_contains "the idle gate is the holder count" \
  "readonly property bool ticking: root._holders > 0" "$CLK"
t_eq "there is one acquire" "1" "$(grep -c 'function acquire()' "$CLOCK")"
t_eq "there is one release" "1" "$(grep -c 'function release()' "$CLOCK")"

t_section "a transport restart re-reads the source"
# Previous on the first track can restart it without a new track identity.
# Both transport surfaces must re-read at that edge; the value stays derived.
for pair in "player view:$OV_SRC" "bar island:$IS_SRC"; do
  label="${pair%%:*}"
  src="${pair#*:}"
  t_contains "$label re-reads on a track edge" \
    "function onTrackChanged() { if (root.player) root.player.positionChanged() }" "$src"
  t_contains "$label re-reads on a state edge" "function onPlaybackStateChanged()" "$src"
done
PANE_SRC="$(<"$SHELL_DIR/common/LyricsPane.qml")"
t_contains "a backward jump retires the reader pin" \
  "root.position + 0.5 < root._lastPosition" "$PANE_SRC"

t_section "the shown lane is a derivation on every surface"
for pair in "player view:$OV_SRC" "bar island:$IS_SRC" "lock pill:$LK_SRC"; do
  label="${pair%%:*}"
  src="${pair#*:}"
  t_contains "$label declares a readonly shown position" \
    "readonly property real shownPosition:" "$src"
  t_contains "$label reads the live player through the shared accessor" \
    "NP.reanchorPosition(root.player, root.lengthSec)" "$src"
  t_not_match "$label never writes the shown position" 'shownPosition =' "$src"
  t_not_match "$label keeps no reanchor copy" 'function reanchor\(' "$src"
done

t_section "the scrub preview is the only local writer"
t_contains "the player view declares one preview" \
  "property real previewPosition: 0" "$OV_SRC"
t_contains "the bar island declares one preview" \
  "property real previewPosition: 0" "$IS_SRC"
t_contains "the player view gates the lane on the drag" \
  "readonly property real shownPosition: root._seeking ? root.previewPosition : NP.reanchorPosition(root.player, root.lengthSec)" "$OV_SRC"
t_contains "the bar island gates the lane on the drag" \
  "readonly property real shownPosition: root._seeking ? root.previewPosition : NP.reanchorPosition(root.player, root.lengthSec)" "$IS_SRC"
t_eq "only the two seeking surfaces write a preview" "2" \
  "$(grep -l 'previewPosition =' "$OVERLAY" "$ISLAND" "$LOCK" | wc -l)"
t_not_match "the lock pill has no preview to write" 'previewPosition' "$LK_SRC"

t_section "every tick has one owner, one reader"
# One Connections-to-clock per surface, each emitting its own player's notify;
# no surface keeps a second private driver of the same value.
t_eq "three surfaces read the shared tick" "3" \
  "$(grep -l 'target: PlaybackClock' "$OVERLAY" "$ISLAND" "$LOCK" | wc -l)"
t_eq "each surface holds the clock once" "3" \
  "$(grep -l 'PlaybackClockHold' "$OVERLAY" "$ISLAND" "$LOCK" | wc -l)"

t_summary
