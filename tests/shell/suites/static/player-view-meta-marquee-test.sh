#!/bin/bash
# Suite: player-view-meta-marquee - overflowing title and artist scroll.
#
# The two lines under the Player view's cover use the bar island's ScrollLabel,
# so a track name or artist wider than its column eases out and back instead of
# being elided. The marquee is gated only on the window being open: it never
# reads MotionPolicy, so turning shell motion off cannot suppress a reading aid.
#
# SOURCE suite: the surface owns a Window and MultiEffect passes that cannot be
# constructed offscreen. The shared marquee animation itself is covered by its
# own QML suite; this suite pins the call site and the pass-through it needs.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "player-view-meta-marquee" "title and artist scroll when they overflow"

OVERLAY="$SHELL_DIR/features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml"
LABEL="$SHELL_DIR/common/ui/ScrollLabel.qml"
t_file "the Player view source exists" "$OVERLAY"
t_file "the shared marquee label exists" "$LABEL"
OV_SRC="$(<"$OVERLAY")"
LB_SRC="$(<"$LABEL")"

t_section "both meta lines use the shared marquee"
t_eq "the Player view has two marquee labels" "2" \
  "$(grep -c 'ScrollLabel {' "$OVERLAY")"
t_eq "both are gated on the window being open" "2" \
  "$(grep -c 'scrolling: root.opened' "$OVERLAY")"
t_eq "both start moving without a reading pause" "2" \
  "$(grep -c 'startPauseMs: 0' "$OVERLAY")"
t_contains "the title keeps its font size" "fontSize: content.trackPx" "$OV_SRC"
t_contains "the artist keeps its font size" "fontSize: content.artistPx" "$OV_SRC"
# The meta column is the slice between its own comment and the transport row;
# other parts of this window legitimately centre text and read animOn.
META="$(awk '/The recording.s own name, one centred line/{f=1} f{print} /Transport: previous, play/{exit}' "$OVERLAY")"
t_eq "both stay centred in their column" "2" \
  "$(printf '%s' "$META" | grep -c 'horizontalAlignment: Text.AlignHCenter')"

t_section "motion policy cannot reach the marquee"
t_eq "only the two meta lines have a scrolling gate" "2" \
  "$(grep -c 'scrolling:' "$OVERLAY")"
t_true "the meta column reads no motion flag" \
  bash -c '! printf "%s" "$1" | sed "/^[[:space:]]*\\/\\//d" | grep -q -E "animOn|MotionPolicy"' _ "$META"
t_contains "ScrollLabel has no policy check of its own" \
  "property bool scrolling: true" "$LB_SRC"
t_not_match "ScrollLabel never reads MotionPolicy" 'MotionPolicy' "$LB_SRC"

t_section "the shared label supports centred text"
t_contains "horizontal alignment is a pass-through" \
  "property alias horizontalAlignment: label.horizontalAlignment" "$LB_SRC"

t_summary
