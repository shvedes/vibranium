#!/bin/bash
# Suite: mpris-display-text - one normalized reading of every metadata field.
#
# MPRIS text is free form: a client may publish a title or artist with embedded
# newlines, tabs or runs of spaces. Rendered as-is, the Player view's meta lines
# wrap into the transport row and the tooltip's icon rows break their height.
# NowPlaying.js folds all whitespace once; every surface reads that one value.
# The raw text is kept only for the identity key in the same library.
#
# SOURCE suite: no shell surface can be constructed offscreen with real MPRIS
# metadata, so the contract is pinned statically; the pure folding is unit-tested
# in the bar-models JS suite.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "mpris-display-text" "metadata is one line on every surface"

LIB="$SHELL_DIR/common/NowPlaying.js"
BAR="$SHELL_DIR/features/bar/modules/NowPlaying/NowPlaying.qml"
ISLAND="$SHELL_DIR/features/bar/modules/NowPlaying/NowPlayingIsland.qml"
LOCK="$SHELL_DIR/features/lock/NowPlaying.qml"
PANE="$SHELL_DIR/common/LyricsPane.qml"
WINDOW="$SHELL_DIR/features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml"
t_file "the shared library exists" "$LIB"
LIB_SRC="$(<"$LIB")"

t_section "one pure fold in the shared library"
t_contains "the helper is published once" "function displayText(value)" "$LIB_SRC"
t_contains "all whitespace folds to one space" 'replace(/\s+/g, " ")' "$LIB_SRC"
t_eq "only the identity key reads raw text" "1" \
  "$(grep -c 'p.trackTitle' "$LIB")"

t_section "every display surface uses the fold"
for pair in "bar module:$BAR" "bar island:$ISLAND" "lock pill:$LOCK" "lyrics pane:$PANE" "player view:$WINDOW"; do
  label="${pair%%:*}"
  file="${pair#*:}"
  t_eq "$label folds all three fields" "3" \
    "$(grep -c 'NP.displayText(root.player.track' "$file")"
  t_not_match "$label never renders a raw tag" 'property string.*root.player.track' "$file"
done

t_section "the player view's meta lines read the folded values"
WIN_SRC="$(<"$WINDOW")"
t_contains "the title line is folded" "text: root.title" "$WIN_SRC"
t_contains "the artist line is folded" "text: root.artist" "$WIN_SRC"
t_contains "the track gate uses the folded title" "readonly property bool hasTrack: root.title !== \"\"" "$WIN_SRC"

t_summary
