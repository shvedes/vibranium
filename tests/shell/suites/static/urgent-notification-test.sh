#!/bin/bash
# Suite: urgent-notification - an urgent card is red-shifted, and the shift is
# the theme's own.
#
# A critical notification used to be told apart by its border alone: a red 2px
# edge around the theme's background. The edge is thin and the surface behind
# it is the same one every other card has, so the urgency was a thing you had
# to notice rather than a thing you saw. The card's own surface now carries
# it - the theme's background shifted thirty percent toward the theme's red -
# so the urgency is on the card rather than on its outline.
#
# Two properties of that shift are load-bearing, and both are invisible in a
# screenshot:
#
#   1. The shift is made of PALETTE leaves, not of a colour chosen here. A
#      hardcoded tint would be the wrong red in every theme but one, and the
#      card would stop following the theme the shell already follows for
#      everything else on it.
#   2. The urgency is read off the entry's SNAPSHOT rather than off the live
#      Notification. The Notification is destroyed the moment `closed` returns
#      and the card is still on screen for its exit fade, so a live read
#      answers "not urgent" for the length of that fade - the card would lose
#      its urgent face exactly as it left.
#
# This is pinned as a SOURCE rule rather than as a runtime assertion, because
# the card cannot be constructed headlessly: it reaches the notifications
# singleton, which the construction suite classifies needs-environment (no
# PanelWindow backend under QT_QPA_PLATFORM=offscreen), so there is no live
# Quickshell to paint a card in. What CAN be checked without a compositor is
# the shape of the rule itself, and that is what the assertions below are.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "urgent-notification" "an urgent card is the theme's background, shifted toward the theme's red"

CARD="$SHELL_DIR/features/notifications/NotificationCard.qml"
ENTRY="$SHELL_DIR/features/notifications/NotificationEntry.qml"
CONTROLLER="$SHELL_DIR/features/notifications/Notifications.qml"
# t_contains takes a haystack STRING, so every assertion below is handed file
# contents rather than a path. $(<f) is the project's own idiom for that.
CARD_SRC="$(<"$CARD")"
ENTRY_SRC="$(<"$ENTRY")"
CONTROLLER_SRC="$(<"$CONTROLLER")"

t_section "the card's surface is a blend of two palette leaves"

t_file "the card is where the surface is drawn" "$CARD"
t_contains "the card blends the background leaf" 'Ui.mix("background_0", "red"' "$CARD_SRC"
t_contains "toward the red leaf" 'Ui.mix("background_0", "red", root.urgentMix)' "$CARD_SRC"
# The share is a named property rather than a literal in the expression, so
# the number that decides how red an urgent card is has one place to live.
t_contains "and the share is a named property" "readonly property real urgentMix" "$CARD_SRC"
t_contains "which is five percent" "readonly property real urgentMix: 0.05" "$CARD_SRC"
# The card's own background is that blend, and only for an urgent card: the
# rest keep the theme's plain background.
t_contains "the card's colour is the blend" "color: root.fill" "$CARD_SRC"
t_contains "and the blend is the urgent branch" "readonly property color fill: root.urgent" "$CARD_SRC"
t_contains "the plain branch is the theme background" 'Ui.solid("background_0")' "$CARD_SRC"

t_section "the urgency is read off the snapshot, not off the live Notification"

t_contains "the card reads the urgency from the snapshot" "root.shot.urgency" "$CARD_SRC"
t_contains "and compares it with the Critical urgency" "=== NotificationUrgency.Critical" "$CARD_SRC"
# The live read is the one that answers "not urgent" for the length of the
# exit fade, so its absence is the assertion rather than a detail.
t_not_contains "the card does not read the live urgency" "entry.critical" "$CARD_SRC"
t_contains "the border reads the same urgent flag" "readonly property color baseBorder: root.urgent" "$CARD_SRC"

t_section "the snapshot carries the urgency, so the field always exists"

t_contains "the card's empty snapshot has the field" "urgency: -1," "$CARD_SRC"
t_contains "and so does the entry's" "urgency: -1," "$ENTRY_SRC"
t_contains "the controller copies the urgency into the snapshot" "urgency: Number(n.urgency)" "$CONTROLLER_SRC"

t_section "the card's first frame is already urgent"

# The pile's change is what creates the card, so the snapshot has to be in
# place before the entry joins the pile: a card built against an empty
# snapshot would paint its first frame without the urgency it has, and the
# border's own tween would carry that wrong colour into the card's arrival.
SNAPSHOT_LINE="$(grep -n 'entry.snapshot = snapshot' "$CONTROLLER" | head -1 | cut -d: -f1)"
PILE_LINE="$(grep -n 'root._tracked = root._tracked.concat' "$CONTROLLER" | head -1 | cut -d: -f1)"
t_not_empty "the controller assigns the snapshot" "$SNAPSHOT_LINE"
t_not_empty "and publishes the entry into the pile" "$PILE_LINE"
if [[ -n $SNAPSHOT_LINE && -n $PILE_LINE ]]; then
  t_true "the snapshot is in place before the card is created" \
    test "$SNAPSHOT_LINE" -lt "$PILE_LINE"
fi

t_summary
