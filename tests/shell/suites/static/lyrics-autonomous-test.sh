#!/bin/bash
# Suite: lyrics-autonomous - the Player view transcript takes no reader input.
#
# The Player window shows lyrics as a document driven by the clock: no hover,
# no tap-to-seek, no wheel or drag scroll, no right-click dismiss. LyricsPane
# owns one `interactive` gate that disables every handler and keeps the
# reader-pin latch from being set without a reader. The presentation surfaces
# opt out; the bar island keeps the default and stays interactive.
#
# SOURCE suite: the pane is shared with surfaces that own windows and pointer
# delivery, so offscreen cannot construct those hosts. Every assertion is a
# static read of the real sources.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "lyrics-autonomous" "one gate disables every lyrics input handler"

PANE="$SHELL_DIR/common/LyricsPane.qml"
OVERLAY="$SHELL_DIR/features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml"
ISLAND="$SHELL_DIR/features/bar/modules/NowPlaying/NowPlayingIsland.qml"
LOCK="$SHELL_DIR/features/lock/NowPlaying.qml"
t_file "the shared pane exists" "$PANE"
t_file "the Player view source exists" "$OVERLAY"
PANE_SRC="$(<"$PANE")"
OV_SRC="$(<"$OVERLAY")"

t_section "the pane publishes one input gate"
t_contains "the gate defaults to interactive" \
  "property bool interactive: true" "$PANE_SRC"
t_contains "the view cannot be dragged or wheeled when off" \
  "interactive: root.scrollable && root.interactive" "$PANE_SRC"
t_contains "the reader-pin latch ignores autonomous content moves" \
  "if (!root.interactive) return" "$PANE_SRC"
t_contains "hover cannot tint a quiet line when off" \
  "root.interactive && lineHovered ? 0.65 : 0.4" "$PANE_SRC"
t_contains "the tap handler never shows a pointing hand" \
  "root.interactive && root.seekable && root.synced ? Qt.PointingHandCursor : Qt.ArrowCursor" "$PANE_SRC"
t_contains "the dismiss area never shows a pointing hand" \
  "root.interactive && root.dismissable ? Qt.PointingHandCursor : Qt.ArrowCursor" "$PANE_SRC"

t_section "every handler is gated"
t_contains "the tap handler is off" \
  "enabled: root.interactive" "$PANE_SRC"
# Tap and hover carry the gate directly; the dismiss MouseArea carries it with
# its own capability flag, asserted below.
t_eq "tap and hover handlers are gated" "2" \
  "$(grep -c 'enabled: root.interactive' "$PANE")"
t_contains "the dismiss area needs both flags" \
  "enabled: root.dismissable && root.interactive" "$PANE_SRC"

t_section "the Player view opts out; other surfaces do not"
t_contains "the Player view turns the gate off" \
  "interactive: false" "$OV_SRC"
# The gate is the only policy the host declares. The capability flags are
# derived inside the pane, so no second copy of the decision can go stale.
t_not_match "no capability flag duplicates the gate" \
  'seekable:|dismissable:|scrollable:' "$OV_SRC"
t_eq "the bar island keeps the default" "0" \
  "$(grep -c 'interactive: false' "$ISLAND")"
t_eq "the lock pill keeps the default" "0" \
  "$(grep -c 'interactive: false' "$LOCK")"

t_summary
