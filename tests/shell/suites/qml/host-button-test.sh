#!/bin/bash
# Suite: common/ui - IslandHost and IconButton, the popup host and the icon
# button, driven through a real event loop.
#
# IslandHost is a PanelWindow, and QT_QPA_PLATFORM=offscreen has no PanelWindow
# backend, so the component cannot be constructed at all. The probe
# (probes/host-button.qml) therefore reads the real common/ui/IslandHost.qml,
# rewrites only the window-only surface - the root type and the twelve
# window/layershell property lines, the PanelWindow signal handler and the
# HyprlandFocusGrab block - and evaluates the result. Every function, the Card,
# the Loader and the Connections are the file's own bytes, so the state
# machine, the frozen footprint cache, the key derivation, diagnostics() and
# positionCard are all measured rather than read.
#
# The rewrite is held to the file it rewrites: the probe reports the lines it
# removed and the functions that survived, and the sections below assert both.
# A source change the rewrite no longer understands fails here rather than
# quietly testing something else.
#
# What is still not reached, and is not claimed: window mapping, layershell
# state, the compositor focus grab, ESC and outside-click dismissal, a real
# mouse press or hover, keyboard focus, and anything needing a second output.
# Those are listed as skips at the end with their reasons.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "host-button" "IslandHost: state machine, frozen footprint, anchoring; IconButton: derived state, gates, geometry"

ISLAND_HOST="$SHELL_DIR/common/ui/IslandHost.qml"
ICON_BUTTON="$SHELL_DIR/common/ui/IconButton.qml"
FROZEN_FOOTPRINT="$SHELL_DIR/common/collections/FrozenFootprint.js"

# lt <label> <a> <b> and gt <label> <a> <b> - ordering on the probe's numbers.
# The kit has no numeric assertion, and `test` rejects the doubles a tween
# reports ("test: 0.6: integer expected"), so the comparison goes through awk
# and t_true, which keeps the result in the same result file as everything else.
lt() {
  t_true "$1" awk -v a="$2" -v b="$3" 'BEGIN { exit !(a < b) }'
}
gt() {
  t_true "$1" awk -v a="$2" -v b="$3" 'BEGIN { exit !(a > b) }'
}

require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/host-button.qml" 40; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"
# Motion assertions are conditional because the environment may disable the
# global animation policy while all state-machine checks remain meaningful.
MOTION_ENABLED="$(qp_get ih.motionEnabled)"
t_eq "the host reflects the global motion policy" "$(qp_get ih.motionEnabled)" "$(qp_get ih.animationsEnabled.default)"

# ---------------------------------------------------------------------------
t_section "the headless rewrite is the component, minus its window surface"
# A PanelWindow has no offscreen backend, so the probe swaps the root type and
# drops the lines that only exist on a window. These are the properties of that
# rewrite: if the file grows a new window-only line, the count changes and the
# suite says so instead of testing a stale rewrite.
t_eq "the source was read whole" "200" "$(qp_get hl.sourceStatus)"
t_eq "the real component's root type is what the rewrite keys on" "true" "$(qp_get hl.sourceIsPanelWindow)"
t_eq "and the rewritten root is a constructible Item" "true" "$(qp_get hl.rootTypeIsItem)"
t_eq "window-only properties and the full visibility handler were removed" "16" "$(qp_get hl.droppedCount)"
t_eq "the whole HyprlandFocusGrab block was removed" "5" "$(qp_get hl.grabLines)"
t_eq "the focus grab is gone from the evaluated text" "true" "$(qp_get hl.dropsGrab)"
t_eq "so is every layershell line" "true" "$(qp_get hl.dropsLayershell)"
t_contains "including the screen binding" "screen: root.anchorScreen()" "$(qp_get hl.droppedLines)"
t_contains "including the layershell layer" "WlrLayershell.layer: WlrLayer.Top" "$(qp_get hl.droppedLines)"
t_contains "including the exclusive zone" "exclusiveZone: -1" "$(qp_get hl.droppedLines)"
t_contains "including the PanelWindow signal handler" "onBackingWindowVisibleChanged:" "$(qp_get hl.droppedLines)"
# The other half of the contract: everything the assertions are about survived.
PUBLIC_SURFACE+="_frozenH,_frozenW,_keyFor,_navBlocked,_navTarget,_saveFrozen,"
PUBLIC_SURFACE+="anchorScreen,beginFocusPrime,close,diagnostics,grabNavFocus,grabWindows,"
PUBLIC_SURFACE+="isOpenFor,onIslandContentHeightChanged,onIslandContentWidthChanged,"
PUBLIC_SURFACE+="positionCard,requestPark,show,toggle"
t_eq "the public surface is intact" "$PUBLIC_SURFACE" "$(qp_get hl.functions)"
t_eq "the Loader survived" "true" "$(qp_get hl.keepsLoader)"
t_eq "the Card survived" "true" "$(qp_get hl.keepsCard)"
t_eq "the footprint write survived" "true" "$(qp_get hl.keepsSaveCall)"
t_eq "so did the bound it is created with" "true" "$(qp_get hl.keepsCapacityBind)"
t_eq "the map-visibility expression survived" "true" "$(qp_get hl.keepsVisible)"
t_eq "positionCard survived" "true" "$(qp_get hl.keepsPositionCard)"
t_eq "_keyFor survived" "true" "$(qp_get hl.keepsKeyFor)"
t_eq "forty distinct slot ids were built for the eviction bound" "40" "$(qp_get hl.floodDistinct)"
t_eq "the first is the first" "slot-0" "$(qp_get hl.floodKey0)"
t_eq "and the fortieth is the fortieth" "slot-39" "$(qp_get hl.floodKey39)"
t_note "the rewrite is what lets this suite reach IslandHost's logic at all; the
component's own header (IslandHost.qml:95-97) records that the map was extracted
to FrozenFootprint.js precisely because a PanelWindow cannot be loaded by a test
runner, but the state machine above it still could not be driven"

# ---------------------------------------------------------------------------
t_section "IslandHost's defaults and the diagnostics shape"
qp_assert "the host was constructed" "ih.built" "true"
qp_assert "the footprint bound is 32" "ih.capacity" "32"
qp_assert "a fresh host is closed" "ih.open.initial" "false"
qp_assert "and is open for nothing" "ih.isOpenFor.initial" "false"
qp_assert "a bar on top is the default" "ih.barPosition.default" "top"
qp_assert "the margin is the spacing token" "ih.margin.default" "8"
qp_assert "which is Ui.s" "ih.tokenS" "8"
qp_assert "no anchor is served" "ih.anchorItem.default" "null"
qp_assert "no content component is lent" "ih.contentComponent.default" "null"
qp_assert "and nothing is loaded" "ih.content.default" "null"
qp_assert "the fallback key is the default one" "ih.key.default" "default"
qp_assert "the motion switch follows the global one" "ih.animationsEnabled.default" "$MOTION_ENABLED"
# diagnostics() is read by a diagnostic dump elsewhere, so its key set is a
# contract: eight keys, no more.
qp_assert "diagnostics() returns exactly eight keys" "ih.diag.keys" \
  "active,capacity,cardHeight,cardWidth,contentLive,count,key,keys"
qp_assert "an empty store counts zero" "ih.diag.count" "0"
qp_assert "and reports the bound it was created with" "ih.diag.capacity" "32"
qp_assert "the key is the fallback before anything is shown" "ih.diag.key" "default"
qp_assert "no content is live" "ih.diag.contentLive" "false"
t_empty "an empty store has no active key" "$(qp_get ih.diag.active)"
t_empty "and no keys at all" "$(qp_get ih.diag.keysList)"
qp_assert "a closed card has no width" "ih.diag.cardWidth" "0"
qp_assert "and no height" "ih.diag.cardHeight" "0"
# An unseen key must miss, never inherit.
qp_assert "an unseen key has no frozen width" "ih.frozen.unseenW" "0"
qp_assert "an unseen key has no frozen height" "ih.frozen.unseenH" "0"
qp_assert "not even the fallback key has one" "ih.frozen.unseenDefaultW" "0"

# ---------------------------------------------------------------------------
t_section "the key is the opener's slot id, and two different slots never share one"
qp_assert "a module with a moduleId keys on it" "ih.key.volume" "volume"
qp_assert "a different moduleId is a different key" "ih.key.wifi" "wifi"
qp_assert "which is the property the suite is hunting for" "ih.key.distinct" "true"
qp_assert "the same anchor keys the same way every time" "ih.key.stable" "true"
qp_assert "two items of one slot share that slot's key" "ih.key.twinsCollide" "true"
qp_assert "and the twin's own key is that slot" "ih.key.twin" "volume"
qp_assert "an anchor Group/Zone has not wired falls back" "ih.key.bare" "default"
qp_assert "a null anchor falls back too" "ih.key.null" "default"
qp_assert "and an object that is not an anchor at all" "ih.key.foreignItem" "default"
qp_assert "forty slots derive forty keys" "ih.derive.fortyDistinctKeys" "40"
qp_assert "and the same rule holds after the first show" "ih.derive.distinct" "true"
qp_assert "and two items of one slot do share that slot's key" "ih.derive.twinCollapses" "true"
qp_assert "an unwired anchor is still the fallback" "ih.derive.bareIsDefault" "true"
qp_assert "a null anchor too" "ih.derive.nullIsDefault" "true"
t_note "two bar items sharing one moduleId do share a key (IslandHost.qml:114-119
keys on the slot id, not the item), so two tray entries open the same island
footprint; that is the documented design rather than a collapse, and isOpenFor
still compares the item itself"

# ---------------------------------------------------------------------------
t_section "the open state machine"
qp_assert "show() opens" "ih.show.open" "true"
qp_assert "and serves the anchor it was given" "ih.show.anchor" "true"
qp_assert "and keeps the component it was lent" "ih.show.comp" "true"
qp_assert "the key moves to that anchor's slot" "ih.show.key" "volume"
qp_assert "isOpenFor is true for the served anchor" "ih.show.isOpenForVolume" "true"
qp_assert "false for a different anchor" "ih.show.isOpenForWifi" "false"
qp_assert "false for a different item of the SAME slot" "ih.show.isOpenForTwin" "false"
qp_assert "false for an unwired anchor" "ih.show.isOpenForBare" "false"
qp_assert "false for null" "ih.show.isOpenForNull" "false"
qp_assert "open and isOpenFor agree" "ih.agree.afterShow" "true"
qp_assert "and agree once settled too" "ih.agree.settled" "true"
qp_assert "the content is live one turn after the show" "ih.show.content" "live"
qp_assert "the card's width is already final - it has no Behavior" "ih.show.cardWidth" "300"
qp_assert "while its height is still in flight" "ih.show.cardHeightInFlight" "true"
qp_assert "close() closes" "ih.close.open" "false"
qp_assert "isOpenFor goes false for the served anchor" "ih.close.isOpenForTwin" "false"
qp_assert "and for the slot's other item" "ih.close.isOpenForVolume" "false"
qp_assert "open and isOpenFor still agree" "ih.agree.afterClose" "true"
qp_assert "toggle on a closed host opens it" "ih.toggle.opened" "true"
qp_assert "for the anchor it was passed" "ih.toggle.isOpenForWifi" "true"
qp_assert "not for the one it was serving" "ih.toggle.isOpenForVolume" "false"
qp_assert "and the key moved with it" "ih.toggle.key" "wifi"
qp_assert "open and isOpenFor agree again" "ih.agree.afterToggleOpen" "true"
qp_assert "toggle on an open host closes it" "ih.toggle.shut" "false"
qp_assert "and nothing is open for it afterwards" "ih.toggle.shutIsOpenFor" "false"
qp_assert "a toggle for another anchor switches instead of closing" "ih.toggle.switch.open" "true"
qp_assert "and serves the new one" "ih.toggle.switch.isOpenForWifi" "true"
qp_assert "the key follows the switch" "ih.toggle.switch.key" "volume"
qp_assert "isOpenFor is true for the new anchor" "ih.toggle.switch2.isOpenForVolume" "true"
qp_assert "false for the old one" "ih.toggle.switch2.isOpenForWifi" "false"

# ---------------------------------------------------------------------------
t_section "show() and close() with nothing to show"
qp_assert "a null content component does not throw" "ih.nullComp.noThrow" "true"
qp_assert "and the host is open" "ih.nullComp.open" "true"
qp_assert "the previous content is gone" "ih.nullComp.content" "null"
qp_assert "the component was cleared, not left behind" "ih.nullComp.comp" "null"
qp_assert "isOpenFor still answers for the anchor" "ih.nullComp.isOpenForVolume" "true"
qp_assert "open and isOpenFor agree" "ih.agree.afterNullComp" "true"
qp_assert "with no content live the card is the frozen footprint" "ih.nullComp.cardWidth" "300"
qp_assert "in height" "ih.nullComp.cardHeight" "140"
qp_assert "and that is what the store holds" "ih.nullComp.frozenW" "300"
qp_assert "in height" "ih.nullComp.frozenH" "140"
qp_assert "a null anchor does not throw" "ih.nullAnchor.noThrow" "true"
qp_assert "and the host is open" "ih.nullAnchor.open" "true"
qp_assert "the key falls back to default" "ih.nullAnchor.key" "default"
qp_assert "isOpenFor is true for null" "ih.nullAnchor.isOpenForNull" "true"
qp_assert "and false for a real anchor" "ih.nullAnchor.isOpenForVolume" "false"
qp_assert "open and isOpenFor agree" "ih.agree.afterNullAnchor" "true"
qp_assert "no bar window means no screen" "ih.nullAnchor.screen" "true"
qp_assert "and the focus grab falls back to the host alone" "ih.nullAnchor.grab" "1"
qp_assert "the anchor itself stays null" "ih.nullAnchor.anchor" "null"
qp_assert "the content is live" "ih.nullAnchor.content" "live"
# positionCard returns early without an anchor, so the card keeps the offset the
# last park gave it. Asserted against the value read one turn earlier rather
# than a literal, because the point is that nothing moved.
qp_assert "positionCard is a no-op without an anchor" "ih.nullAnchor.cardXUnchanged" "true"

# ---------------------------------------------------------------------------
t_section "the frozen footprint: a closed host keeps the size its content had"
qp_assert "the content is destroyed once the fade lands" "ih.settle.t32.content" "null"
qp_assert "it is still there one turn before that" "ih.settle.t31.content" "live"
qp_assert "which is what the close fade is for" "ih.close.contentStillLive" "live"
qp_assert "the opacity reaches zero" "ih.closed.opacity" "0"
qp_assert "content is null while closed" "ih.closed.content" "null"
qp_assert "and diagnostics agrees" "ih.closed.contentLive" "false"
# close() deliberately leaves contentComponent set: the Loader needs its source
# through the fade, and the next show() overwrites it.
qp_assert "close() does not clear the lent component" "ih.closed.compStillSet" "true"
qp_assert "the frozen width is the last live width" "ih.closed.frozenW" "300"
qp_assert "the frozen height is the last live height" "ih.closed.frozenH" "400"
qp_assert "so the closed card is exactly that size" "ih.closed.cardWidth" "300"
qp_assert "in width" "ih.closed.cardHeight" "400"
qp_assert "and diagnostics reports that card size" "ih.closed.diagCardW" "300"
qp_assert "in height too" "ih.closed.diagCardH" "400"
qp_assert "one slot is frozen" "ih.closed.count" "1"
qp_assert "the diagnostics key is the served slot" "ih.closed.diagKey" "volume"
qp_assert "a slot that was never served still has nothing" "ih.closed.otherKeyW" "0"
qp_assert "in height as well" "ih.closed.otherKeyH" "0"
# The three slots the host has served by now, each with its own size.
qp_assert "the fallback key got the null-anchor show" "ih.nullAnchor.defaultW" "220"
qp_assert "in height" "ih.nullAnchor.defaultH" "90"
qp_assert "the wifi slot kept its own size" "ih.nullAnchor.wifiW" "220"
qp_assert "in height" "ih.nullAnchor.wifiH" "90"
qp_assert "and the volume slot its own" "ih.nullAnchor.volumeW" "300"
qp_assert "in height" "ih.nullAnchor.volumeH" "140"
# The toggle tests served two more slots, each with its own size: the store
# keys by slot id, so one island's content never sizes another's card.
qp_assert "the wifi slot froze at the content's own size" "ih.toggle2.frozenWifiW" "220"
qp_assert "in height" "ih.toggle2.frozenWifiH" "90"
qp_assert "and the volume slot at its own" "ih.toggle2.frozenVolumeW" "300"
qp_assert "in height" "ih.toggle2.frozenVolumeH" "140"
qp_assert "three distinct slots are now frozen" "ih.nullAnchor.count" "3"
qp_assert "and the most recent one is the active key" "ih.nullAnchor.active" "default"
t_note "the footprint is written from the live content size, not from the card:
the content was resized to 400 while open, and the closed card is 300x400 even
though the tween was still running when the host was closed"

# ---------------------------------------------------------------------------
t_section "the store never grows past its bound"
# 40 distinct slots on one host, one show per event-loop turn, alternating two
# content components so the Loader really does hand out a new content object
# each time (a repeat of the same component keeps the live item and writes
# nothing - see the section below).
qp_assert "the host starts with an empty store" "ih.flood.startCount" "0"
qp_assert "on the fallback key" "ih.flood.startKey" "default"
qp_assert "the flood host runs the same bound" "ih.flood.capacity" "32"
qp_assert "and starts closed and empty" "ih.flood.open" "false"
qp_assert "31 slots in, 31 entries" "ih.flood.countAfter30" "31"
qp_assert "within the bound on that turn" "ih.flood.boundAfter30" "true"
qp_assert "and the slot just served is the newest" "ih.flood.newestAfter30" "slot-30"
qp_assert "and the oldest is still the first" "ih.flood.oldestAfter30" "slot-0"
qp_assert "32 slots in, 32 entries" "ih.flood.countAfter31" "32"
qp_assert "within the bound on that turn too" "ih.flood.boundAfter31" "true"
qp_assert "and the slot just served is still the newest" "ih.flood.newestAfter31" "slot-31"
qp_assert "with its own width" "ih.flood.newestWAfter31" "220"
qp_assert "still nothing evicted at the bound" "ih.flood.oldestAfter31" "slot-0"
qp_assert "33 slots in, the 33rd is refused room" "ih.flood.countAfter32" "32"
qp_assert "still within the bound" "ih.flood.boundAfter32" "true"
qp_assert "and the slot just served is still the newest" "ih.flood.newestAfter32" "slot-32"
qp_assert "with its own width" "ih.flood.newestWAfter32" "300"
qp_assert "so the first entry goes" "ih.flood.oldestAfter32" "slot-1"
qp_assert "34 slots in, still at the bound" "ih.flood.countAfter33" "32"
qp_assert "and the slot just served is still the newest" "ih.flood.newestAfter33" "slot-33"
qp_assert "with its own width" "ih.flood.newestWAfter33" "220"
qp_assert "and one more is gone" "ih.flood.oldestAfter33" "slot-2"
qp_assert "every intermediate count was within the bound" "ih.flood.boundAfter33" "true"
t_eq "40 slots in, the store is at exactly its bound" "32" "$(qp_get ih.flood.finalCount)"
qp_assert "which is the declared bound" "ih.flood.finalAtBound" "true"
qp_assert "and never exceeded it" "ih.flood.finalWithinBound" "true"
t_eq "and diagnostics reports the same bound" "32" "$(qp_get ih.flood.finalCapacity)"
qp_assert "the key list has the same length as the count" "ih.flood.finalKeysCount" "32"
qp_assert "and diagnostics still answers with the same eight keys" "ih.flood.finalDiagKeys" \
  "active,capacity,cardHeight,cardWidth,contentLive,count,key,keys"
# The entry for the slot that is open right now is never the victim of its own
# save: the newest key is the one the host is serving.
qp_assert "the open slot survived" "ih.flood.newestRetained" "slot-39"
qp_assert "and it is the active key" "ih.flood.finalActive" "slot-39"
qp_assert "with its own width" "ih.flood.newestW" "220"
qp_assert "and height" "ih.flood.newestH" "90"
qp_assert "the oldest surviving slot is the 9th" "ih.flood.oldestRetained" "slot-8"
qp_assert "which kept its width" "ih.flood.oldestRetainedW" "300"
qp_assert "the first slot is gone" "ih.flood.firstEvictedW" "0"
qp_assert "and so is the 8th" "ih.flood.lastEvictedW" "0"
qp_assert "while the 9th is not" "ih.flood.keptSlot8W" "300"

# ---------------------------------------------------------------------------
t_section "a collapsed measurement is refused, and the good entry survives"
qp_assert "the slot is open again" "ih.reject.open" "true"
qp_assert "with live content" "ih.reject.content" "live"
qp_assert "the slot held a good size" "ih.reject.beforeW" "300"
qp_assert "in height" "ih.reject.beforeH" "140"
qp_assert "a zero width is set on the content" "ih.reject.zeroWidthSet" "0"
qp_assert "and the live card follows it" "ih.reject.liveWidth" "0"
# FP.save refuses it, so the entry the save would have replaced is untouched
# (IslandHost.qml:120-137).
qp_assert "the frozen width is untouched" "ih.reject.frozenWAfterZero" "300"
qp_assert "the frozen height is untouched" "ih.reject.frozenHAfterZero" "140"
qp_assert "and no new entry appeared" "ih.reject.countAfterZero" "3"
qp_assert "a negative height is set next" "ih.reject.negativeSet" "-5"
qp_assert "typeof -5 is number and isFinite(-5), so only positivity catches it" "ih.reject.frozenHAfterNegative" "140"
qp_assert "and the width is still the good one" "ih.reject.frozenWAfterNegative" "300"
qp_assert "restoring the height is a normal save" "ih.reject.restored" "140"

# ---------------------------------------------------------------------------
t_section "screen anchoring and the park"
qp_assert "offscreen provides exactly one screen" "ih.screen.count" "1"
t_match "with a non-degenerate geometry" '^[1-9][0-9]*$' "$(qp_get ih.screen.width)"
t_match "in both axes" '^[1-9][0-9]*$' "$(qp_get ih.screen.height)"
t_eq "and no name at all - the virtual screen is unnamed" '""' "$(qp_get ih.screen.name)"
t_note "Quickshell's offscreen screen has an empty name, so anchorScreen() is
asserted on identity and geometry rather than on a name; the shell README already
records that multi-output geometry is not verifiable here"
qp_assert "an unwired anchor resolves no screen" "ih.screen.bareIsNull" "true"
qp_assert "and the focus grab falls back to the host alone" "ih.screen.grabBare" "1"
qp_assert "a wired anchor resolves the bar window's screen" "ih.screen.wired" "true"
qp_assert "and it is truthy" "ih.screen.wiredTruthy" "true"
qp_assert "with a bar window the grab takes both windows" "ih.screen.grabWired" "2"
# positionCard: y is the bar height plus the margin for a top bar, x is the
# anchor's centre less half the card, both clamped by the margin.
qp_assert "the card's width is the live content width" "ih.pos.width" "300"
qp_assert "the bar window's height is what the park reads" "ih.pos.barHeight" "40"
qp_assert "a top bar drops the card just under the bar" "ih.pos.cardY" "48"
qp_assert "and the probe's own arithmetic agrees" "ih.pos.expectedY" "48"
qp_assert "a card wider than the anchor parks clamped at the margin" "ih.pos.cardX" "8"
qp_assert "which is what the probe's arithmetic says too" "ih.pos.expectedX" "8"
qp_assert "a bottom bar measures the card up from the bottom edge" "ih.bottom.cardY" "340"
qp_assert "and that is screenH - barH - cardH - margin" "ih.bottom.expectedY" "340"
# The margin is a real term in the park: with the default 8 the same bar would
# park 12px lower, which the probe computes from the same source.
qp_assert "the default margin would park the card lower" "ih.bottom.expectedYMargin8" "352"
# And a module near the right edge has its card clamped away from it.
qp_assert "a module at the right edge clamps the card" "ih.clamp.cardX" "492"
qp_assert "which is screenW - cardW - margin" "ih.clamp.expectedX" "492"
qp_assert "and the card's y is unaffected by the clamp" "ih.clamp.cardY" "48"
qp_assert "the module that was served is the twin" "ih.clamp.anchor" "true"
qp_assert "isOpenFor is true for the module it is serving" "ih.clamp.isOpenForTwin" "true"
qp_assert "false for the other item of that slot" "ih.clamp.isOpenForVolume" "false"

# ---------------------------------------------------------------------------
t_section "the tween paths, sampled in flight"
# The card's width has no Behavior and its height has one, so a resize while
# the island is open moves the height when motion is enabled.
qp_assert "the resize was requested" "ih.resize.requested" "400"
if [[ $MOTION_ENABLED == "true" ]]; then
  qp_assert "the height is mid-flight one turn later" "ih.resize.t13.strict" "true"
  qp_assert "and still mid-flight four turns later" "ih.resize.t17.strict" "true"
  lt "and the height is climbing" "$(qp_get ih.resize.t15.height)" "$(qp_get ih.resize.t17.height)"
  lt "strictly between the two sizes throughout" "$(qp_get ih.resize.t13.height)" "$(qp_get ih.resize.t17.height)"
  # The footprint is written from the measurement, not from the animation, so
  # it is final while the card is still growing.
  qp_assert "the frozen height is final on the first tween turn" "ih.resize.t13.frozen" "400"
  qp_assert "and stays that way" "ih.resize.t17.frozen" "400"
  lt "so the card is still behind its footprint" "$(qp_get ih.resize.t17.height)" "$(qp_get ih.resize.t17.frozen)"
else
  qp_assert "motion-disabled resize is immediate" "ih.resize.settledExact" "true"
  t_skip "IslandHost height tween samples" "MotionPolicy.enabled is false, so the host correctly snaps to its requested height"
fi
qp_assert "the width never moved" "ih.resize.t17.widthUnchanged" "300"
qp_assert "the card reaches the declared size" "ih.resize.settledExact" "true"
t_eq "which is the live height" "400" "$(qp_get ih.resize.settledValue)"
qp_assert "and the frozen width never changed" "ih.resize.landedFrozenW" "300"
# The fade: opacity and height both run, and the no-motion control on the same
# turns is already at its final size.
if [[ $MOTION_ENABLED == "true" ]]; then
  qp_assert "the card is fading in" "ih.fade.t5.opacityStrict" "true"
  qp_assert "the height is growing with it" "ih.fade.t5.heightStrict" "true"
  qp_assert "one turn later the height is still growing" "ih.fade.t6.heightStrict" "true"
  lt "and it is climbing" "$(qp_get ih.fade.t4.height)" "$(qp_get ih.fade.t7.height)"
  qp_assert "there was a turn with both tweens in flight" "ih.fade.sawMidFade" "true"
  qp_assert "the fade completes" "ih.fade.t9.opacity" "1"
  qp_assert "and then opacity is no longer in between" "ih.fade.t9.opacityStrict" "false"
else
  t_skip "IslandHost opening tween samples" "MotionPolicy.enabled is false, so the host correctly snaps instead of animating"
fi
qp_assert "the settled height is the content's" "ih.settled.height" "140"
qp_assert "the settled width is the content's" "ih.settled.width" "300"
qp_assert "and the live content still reports them" "ih.settled.liveHeight" "140"
qp_assert "in width" "ih.settled.liveWidth" "300"
qp_assert "the footprint agrees while open" "ih.settled.frozenH" "140"
qp_assert "in width" "ih.settled.frozenW" "300"
qp_assert "one entry, live content" "ih.settled.contentLive" "true"
qp_assert "and one footprint" "ih.settled.count" "1"
# The close fade, sampled: content outlives the close through it when motion is enabled.
if [[ $MOTION_ENABLED == "true" ]]; then
  qp_assert "the fade is still running five turns after the close" "ih.settle.t29.opacityStrict" "true"
  gt "the opacity is descending" "$(qp_get ih.settle.t27.opacity)" "$(qp_get ih.settle.t31.opacity)"
else
  t_skip "IslandHost close fade samples" "MotionPolicy.enabled is false, so close snaps opacity to zero"
fi
qp_assert "the card is still the content's size" "ih.settle.t31.cardWidth" "300"
t_eq "landing on zero" "0" "$(qp_get ih.settle.t32.opacity)"
t_eq "and the content is gone on that same turn" "null" "$(qp_get ih.settle.t32.content)"

# ---------------------------------------------------------------------------
t_section "finding: the first size evaluation grows instead of snapping"
# IslandHost.qml:253-266 documents that the opacity gate keeps the very first
# size evaluation - the one right after the content incubates, during the
# fade-in - a snap "instead of a grow", so the window maps at its final size.
# Measured: the height tween runs from 0 to the content's declared height across
# the whole fade, on a host whose content is not self-animating, on the same
# turns a host with animationsEnabled false is already at its final size.
FINDING_GROW="FINDING (IslandHost.qml:262-266 vs measured): the first size evaluation
  is a grow, not a snap.
  Input: show() a content declaring islandContentWidth 300 / islandContentHeight
    140, on a host with the default animationsEnabled.
  Expected per the comment: card.height == 140 on the first event-loop turn, so
    the window maps at its final size.
  Actual: the card is mid-glide for the whole fade - 37.9 one turn after the
    show and 140 only nine turns later, on this host, with card.opacity between
    0.4 and 1 the entire time. The width, which has no Behavior, is 300 on the
    first turn, so the card grows tall and narrow.
  Control: the same first open with animationsEnabled false reports height 140
    and opacity 1 on the same turn (ih.fade.noMotion.snapped), so the grow is
    the tween and not a slow measurement. The islandSelfAnimating term of the
    same gate is equally ineffective on that first change
    (ih.fade.t5.selfStrict), while the animationsEnabled term is honoured - which
    points at the first-change ordering rather than at the expression."
t_note "$FINDING_GROW"
qp_assert "the animating host is mid-glide on the first settle turn" "ih.fade.t4.heightStrict" "true"
qp_assert "the no-motion control is at its final size on that turn" "ih.fade.t4.noMotionHeight" "140"
qp_assert "and the control's opacity landed immediately" "ih.fade.noMotion.snapped" "true"
gt "so the two hosts differ by a long way" "$(qp_get ih.fade.t4.noMotionHeight)" "$(qp_get ih.fade.t4.height)"
# A sampled height is the host's turn spacing, so the claim is the relationship:
# the card was mid-glide on a turn where the fade was also in flight, and the
# height tween lands on a later turn than the opacity tween.
qp_assert "there was a turn with both tweens in flight" "ih.fade.sawMidFade" "true"
gt "and the height tween lands after the opacity tween" \
  "$(qp_get ih.fade.heightLandedAt)" "$(qp_get ih.fade.opacityLandedAt)"
qp_assert "a self-animating content is mid-glide as well" "ih.fade.t5.selfStrict" "true"
t_note "the same gate is honoured on every later change: a resize requested while
the island is fully open tweens (ih.resize.t13.strict) and one requested mid-fade
snaps, because the gate is false there - so the defect is confined to the first
change after the content incubates, which is exactly the change the comment is
about"

# ---------------------------------------------------------------------------
t_section "finding: a runtime margin change does not re-park the card"
# positionCard reads root.margin in both axes, and barPosition has an
# onBarPositionChanged that re-parks it (IslandHost.qml:344). margin is a
# public property with no such handler, so a change to it is not applied until
# something else re-parks.
FINDING_MARGIN="FINDING (IslandHost.qml:77 and :344): a runtime margin change does
  not re-park the card.
  Input: an open island, then margin = 20 (from the Ui.s default of 8).
  Expected: the card re-parks 12px further from the bar, since positionCard reads
    root.margin in both axes.
  Actual: card.y stays 48 and card.x stays 8 - the offset the previous park
    produced - and stays there when the margin is put back, until a barPosition
    change re-parks it. The re-parks that do exist are onOpenChanged,
    onAnchorItemChanged and onBarPositionChanged (IslandHost.qml:342-344); there
    is no onMarginChanged beside them.
  Scope: no consumer sets margin at runtime today (BarView.qml:144-148 sets only
    barPosition), so the visible consequence is nil and the risk is the next
    consumer that does. The margin is still a real term in the park: flipping
    barPosition with margin 20 lands y at 340, and the default 8 would have
    landed 352."
t_note "$FINDING_MARGIN"
qp_assert "the margin property did change" "ih.margin.changed" "20"
qp_assert "but the card did not move" "ih.margin.cardY" "48"
qp_assert "nor sideways" "ih.margin.cardX" "8"
qp_assert "a barPosition change does re-park it" "ih.margin.positionFlip" "bottom"
qp_assert "and the park reads the new margin" "ih.bottom.cardY" "340"
qp_assert "restoring the margin is accepted" "ih.bottom.marginRestored" "8"
qp_assert "and the card still does not move for it" "ih.bottom.yAfterMarginRestore" "340"
qp_assert "the bar position goes back too" "ih.restore.position" "top"

# ---------------------------------------------------------------------------
t_section "finding: a slot served by a shared component is never frozen"
# _saveFrozen runs on a content change and on a content size change
# (IslandHost.qml:294-309). show() only assigns contentComponent when it
# differs (IslandHost.qml:160), and the Loader keeps its item while the
# component is unchanged, so a second slot served by the same Component
# produces neither signal - and no footprint for that slot.
FINDING_SHARED="FINDING (IslandHost.qml:157-163 with :294-309): a second anchor
  served by the same content Component never gets a footprint.
  Input: show(anchorShared, compTall) then show(anchorSharedTwin, compTall), with
    the host open.
  Expected per the header contract (IslandHost.qml:89-92, 'Last live content size
    per opener slot id'): a 220x90 entry for shared-twin.
  Actual: _frozenW('shared-twin') is 0 while the open card is 220x90, and once
    the host closes that card settles to 0x0 - a closed island for that slot has
    no size to keep. show() only assigns contentComponent when it differs
    (IslandHost.qml:160) and the Loader keeps its item while the component is
    unchanged, so neither a content change nor a content size change happens, and
    _saveFrozen has nothing to hang off.
  Scope: it needs two slots sharing one Component. A slot served by its own
    Component is fine (shared froze 220x90), and so is a slot whose content
    resizes. Nothing looks wrong while the island is open, which is why the live
    card hid it: the hole only shows once the host closes."
t_note "$FINDING_SHARED"
qp_assert "the first slot is open" "ih.shared.openShared" "true"
qp_assert "under its own key" "ih.shared.keyShared" "shared"
qp_assert "the first slot froze" "ih.shared.frozenSharedW" "220"
qp_assert "the second, same component, did not" "ih.shared.frozenTwinW" "0"
qp_assert "while the open card is the content's width" "ih.shared.cardWidth" "220"
qp_assert "and its height" "ih.shared.cardHeight" "90"
qp_assert "isOpenFor moved to the second slot" "ih.shared.isOpenForTwin" "true"
qp_assert "and left the first" "ih.shared.isOpenForSharedAfter" "false"
qp_assert "the key moved with it" "ih.shared.keyTwin" "shared-twin"
qp_assert "the content is still the same live item" "ih.shared.content" "live"
qp_assert "the store did not grow for it" "ih.shared.count" "4"
qp_assert "once the content is gone that card has no width" "ih.shared.closedTwinW" "0"
t_eq "and settles to no size at all" "0" "$(qp_get ih.settle.t76.cardHeight)"
qp_assert "while the first slot still has its width" "ih.shared.closedSharedW" "220"
qp_assert "and the content really is gone" "ih.shared.closedContent" "null"

# ---------------------------------------------------------------------------
t_section "two IslandHosts on one probe share nothing"
qp_assert "their footprint stores are different objects" "ih.inst.separateStores" "true"
qp_assert "the first is closed" "ih.inst.h1Open" "false"
qp_assert "the second is open" "ih.inst.h2Open" "true"
qp_assert "on its own key" "ih.inst.h2Key" "self"
qp_assert "and the first is on another" "ih.inst.h1Key" "shared-twin"
qp_assert "the first held four footprints before" "ih.inst.h1CountBefore" "4"
qp_assert "and the second one" "ih.inst.h2CountBefore" "1"
qp_assert "opening the second did not open the first" "ih.inst.h1OpenAfter" "false"
qp_assert "and did not grow the first's store" "ih.inst.h1CountUnchanged" "true"
qp_assert "the first's count is still four" "ih.inst.h1CountAfter" "4"
qp_assert "the second's grew by its own one" "ih.inst.h2CountAfter" "2"
qp_assert "and it really is open" "ih.inst.h2Opened" "true"
qp_assert "under the key it was shown for" "ih.inst.h2KeyAfter" "second-only"
qp_assert "a slot only the second served is frozen there" "ih.inst.h2FrozenSecondOnly" "300"
qp_assert "and absent from the first" "ih.inst.h1FrozenSecondOnly" "0"
qp_assert "the second's earlier slot is frozen there" "ih.inst.h2FrozenSelf" "260"
qp_assert "and absent from the first" "ih.inst.h1FrozenSelf" "0"
qp_assert "the first has no content" "ih.inst.h1Content" "null"
qp_assert "the second does" "ih.inst.h2Content" "live"
qp_assert "and the first is open for nothing" "ih.inst.h1IsOpenForShared" "false"
qp_assert "while the second is open for its slot" "ih.inst.h2IsOpenForSecond" "true"
qp_assert "closing one does not disturb the other" "ih.inst.h3Closed" "true"

# ---------------------------------------------------------------------------
t_section "IconButton: defaults, and one fixed slot for both content modes"
t_eq "no name by default" '""' "$(qp_get ib.defaults.name)"
qp_assert "the palette key defaults to foreground_0" "ib.defaults.colorKey" "foreground_0"
t_eq "no accent key" '""' "$(qp_get ib.defaults.accentKey)"
t_eq "no glyph" '""' "$(qp_get ib.defaults.glyph)"
qp_assert "no dim tiers" "ib.defaults.dimTiers" "0"
qp_assert "not bright" "ib.defaults.bright" "false"
qp_assert "not faint" "ib.defaults.faint" "false"
qp_assert "not flat" "ib.defaults.flat" "false"
qp_assert "iconSize 0 means the bar tokens" "ib.defaults.iconSize" "0"
qp_assert "and slotSize 0 means the token sizes" "ib.defaults.slotSize" "0"
qp_assert "corners are square by default" "ib.defaults.cornerRadius" "0"
qp_assert "and radius aliases it" "ib.defaults.radius" "0"
qp_assert "icons paint at full opacity" "ib.defaults.iconOpacity" "1"
qp_assert "the motion switch follows the global one" "ib.defaults.animationsEnabled" "$MOTION_ENABLED"
qp_assert "the button is enabled" "ib.defaults.enabled" "true"
qp_assert "and fully opaque" "ib.defaults.opacity" "1"
qp_assert "unpressed scale is 1" "ib.defaults.scale" "1"
t_eq "no tip text" '""' "$(qp_get ib.defaults.tipText)"
qp_assert "so no tip bubble" "ib.defaults.tipShown" "false"
qp_assert "forceHover is off" "ib.defaults.forceHover" "false"
# iconMode keys off name alone, which is why a glyph button is not icon mode.
qp_assert "an empty name is glyph mode" "ib.mode.empty" "false"
qp_assert "a name is icon mode" "ib.mode.named" "true"
qp_assert "a glyph alone is not" "ib.mode.glyph" "false"
qp_assert "the glyph Text is visible in glyph mode" "ib.glyph.text.visible" "true"
qp_assert "and the Icon is not" "ib.glyph.icon.visible" "false"
qp_assert "in icon mode the Icon is visible" "ib.named.icon.visible" "true"
qp_assert "and the Text is not" "ib.named.text.visible" "false"
# The slot is a function of the tokens, so a bar that scales with the font
# scales the hit target with it (Icon.qml:64-67).
qp_assert "the derived slot is the token, clamped to [12, 24]" "ib.mode.tokenSlot" "24"
qp_assert "and the probe's own formula agrees" "ib.mode.tokenFormula" "24"
qp_assert "the optical canvas is derived too" "ib.mode.tokenCanvas" "14"
qp_assert "from the canvas token" "ib.mode.canvasFormula" "14"
qp_assert "and matches" "ib.mode.canvasMatches" "true"
qp_assert "glyph mode keeps the legacy 16px micro-button" "ib.mode.glyphTarget" "16"
qp_assert "icon mode sizes from the bar token" "ib.mode.iconTarget" "24"
# slotSize is the opt-in bespoke outer slot, in both modes.
qp_assert "slotSize wins in glyph mode" "ib.mode.slotOverridesGlyph" "20"
qp_assert "and in icon mode" "ib.mode.slotOverrides" "40"
qp_assert "the width follows the target size" "ib.mode.slotWins" "true"
qp_assert "a zero slotSize does not win" "ib.mode.slotZeroLoses" "true"
# iconSize paints inside the slot and never resizes it.
qp_assert "iconSize reaches the Icon" "ib.mode.iconSizeForwards" "18"
qp_assert "without touching the slot" "ib.mode.iconSizeKeepsSlot" "40"
qp_assert "zero means the canvas tokens" "ib.mode.iconSizeZeroUsesTokens" "0"
qp_assert "the icon name is forwarded" "ib.mode.iconNameForwards" "volume-max"
qp_assert "and so is the palette key" "ib.mode.colorKeyForwards" "foreground_0"
qp_assert "and the dim tiers" "ib.mode.dimTiersForwards" "2"

# ---------------------------------------------------------------------------
t_section "IconButton: the interaction gate"
# hovered and pressed are both gated on live (IconButton.qml:80-81), which is
# the conjunction of the hard `enabled` lock and the soft `actionable` gate,
# so a disabled button must report neither even with forceHover set.
qp_assert "forceHover makes hovered true" "ib.hover.force" "true"
qp_assert "without the native control ever seeing a cursor" "ib.hover.force.nativeStaysFalse" "false"
qp_assert "and without popping the tip bubble" "ib.hover.force.tipStaysHidden" "false"
qp_assert "a disabled button is not hovered, forceHover or not" "ib.hover.disabledHovered" "false"
qp_assert "and not pressed" "ib.hover.disabledPressed" "false"
qp_assert "it reports itself disabled" "ib.hover.disabledEnabled" "false"
qp_assert "the native control is disabled with it" "ib.hover.disabledNativeEnabled" "false"
qp_assert "and the shell dims it" "ib.hover.disabledOpacity" "0.4"
qp_assert "a resting button is live" "ib.hover.plainIsLive" "true"
qp_assert "a resting button is not hovered" "ib.hover.restingHovered" "false"
qp_assert "nor pressed" "ib.hover.restingPressed" "false"
qp_assert "the resting button has no focus" "ib.hover.focused" "false"
qp_assert "the native control agrees it is unpressed" "ib.defaults.nativePressed" "false"
qp_assert "and unhovered" "ib.defaults.nativeHovered" "false"
qp_assert "and takes focus but is not a tab stop" "ib.defaults.nativeFocusOnTab" "false"
# clicked(): the wrapper re-emits the native signal (IconButton.qml:119). A
# real mouse click needs a compositor, so the native signal is emitted instead -
# that covers the wiring and the handler, not the platform's press mapping.
t_note "the press state is unreachable headlessly: AbstractButton.pressed is
read-only and is set by the platform's press handling, so with no compositor and
no window there is no API to move it. The suite asserts pressed stays false at
rest and that the enabled gate reports it false on a disabled button, and drives
clicked() by emitting the native signal the wrapper re-emits - so the wrapper's
wiring and a handler's arity are covered, the platform's press-to-click mapping
is not"
qp_assert "no handler has fired yet" "ib.click.count" "0"
qp_assert "one native click is one activation" "ib.click.afterOne" "1"
qp_assert "two are two" "ib.click.afterTwo" "2"
qp_assert "and the wrapper's own signal is callable too" "ib.click.afterOwnSignal" "3"
qp_assert "an inert button is not live" "ib.hover.inertLive" "false"
qp_assert "though it is still enabled, which is what keeps a cursor in reach" \
  "ib.hover.inertEnabled" "true"
qp_assert "and the native control with it" "ib.hover.inertNativeEnabled" "true"
qp_assert "it reports neither hovered" "ib.hover.inertHovered" "false"
qp_assert "nor pressed" "ib.hover.inertPressed" "false"
qp_assert "and it does not take the shell's own dim" "ib.hover.inertOpacity" "1"
qp_assert "so the resting ground is the resting ground" "ib.hover.inertGround" "#00000000"
qp_assert "both gates at once read as the hard lock" "ib.hover.bothLive" "false"
qp_assert "so it is not hovered either" "ib.hover.bothHovered" "false"
qp_assert "and it does take the dim" "ib.hover.bothDimmed" "0.4"
qp_assert "a native click on an inert button does not activate it" "ib.click.inertNative" "0"
qp_assert "the tip text is carried" "ib.tip.tipText" "hello"
qp_assert "but no cursor means no bubble" "ib.tip.shown" "false"
qp_assert "and the native control never saw a hover" "ib.tip.nativeHovered" "false"

# ---------------------------------------------------------------------------
t_section "IconButton: the ground is a three-step ladder"
# Each rung is checked through the alpha channel rather than a pinned theme
# colour, so the assertion is about the tint the source asks for.
t_eq "the resting ground is transparent black" "#00000000" "$(qp_get ib.defaults.color)"
qp_assert "and the chrome paints it" "ib.defaults.bgColor" "#00000000"
qp_assert "the resting border is a 1px line" "ib.defaults.bgBorderWidth" "1"
qp_assert "on square corners" "ib.defaults.bgRadius" "0"
qp_assert "the content item holds the icon and the glyph" "ib.defaults.contentItemChildren" "2"
qp_assert "the native control has no focus" "ib.defaults.nativeActiveFocus" "false"
qp_assert "the wrapper's own focus readout agrees" "ib.defaults.focused" "false"
t_eq "the slot is 16 wide" "16" "$(qp_get ib.defaults.width)"
t_eq "and 16 high" "16" "$(qp_get ib.defaults.height)"
t_eq "which is the target size" "16" "$(qp_get ib.defaults.targetSize)"
qp_assert "the resting ground is transparent" "ib.defaults.restIsTransparent" "true"
t_eq "with alpha 0" "0" "$(qp_get ib.defaults.restAlpha)"
qp_assert "the chrome paints the wrapper's ground, not a style's" "ib.defaults.bgIsGround" "true"
qp_assert "the hover rung is foreground_1 at 0.12" "ib.color.hoverMatches" "true"
t_eq "whose alpha is 31/255" "0.12156862745098039" "$(qp_get ib.color.hoverAlpha)"
qp_assert "the faint rung is foreground_1 at 0.07" "ib.color.faintMatches" "true"
t_eq "whose alpha is 18/255" "0.07058823529411765" "$(qp_get ib.color.faintAlpha)"
# bright (and, on a real press, the same rung) is the accent at 0.15.
qp_assert "the bright rung is accent at 0.15" "ib.color.brightMatches" "true"
t_eq "whose alpha is 38/255" "0.14901960784313725" "$(qp_get ib.color.brightAlpha)"
t_match "and it is a real #AARRGGBB" '^#[0-9a-f]{8}$' "$(qp_get ib.color.bright)"
qp_assert "bright is not the resting ground" "ib.color.brightDiffersFromRest" "true"
qp_assert "nor the hover wash" "ib.color.brightDiffersFromHover" "true"
qp_assert "nor the faint fill" "ib.color.brightDiffersFromFaint" "true"
qp_assert "the resting border is foreground_1 at 0.4" "ib.defaults.restBorder" "true"

# ---------------------------------------------------------------------------
t_section "IconButton: flat and the radius alias"
# flat takes the border away and leaves the geometry alone.
qp_assert "a flat button has no border" "ib.flat.borderWidth" "0"
qp_assert "even when bright" "ib.flat.borderWidthBright" "0"
qp_assert "a non-flat one has a 1px border" "ib.flat.borderWidthOff" "1"
qp_assert "and the flat radius is the corner radius" "ib.flat.radius" "6"
qp_assert "which a non-flat button also has" "ib.flat.radiusOff" "9"
qp_assert "the flat ground is still the ladder's" "ib.flat.color" "#00000000"
qp_assert "same as a non-flat button at rest" "ib.flat.restColor" "#00000000"
qp_assert "a flat button with no focus has a transparent border" "ib.flat.borderTransparent" "#00000000"
qp_assert "so bright can only show in the fill" "ib.flat.brightFill" "$(qp_get expect.accent15)"
qp_assert "and the fill is the bright rung" "ib.flat.brightFill" "$(qp_get expect.accent15)"
qp_assert "a non-flat bright button wears the accent border" "ib.flat.brightBorderIsAccent" "true"
# radius is an alias of cornerRadius on the wrapper and on the chrome.
qp_assert "radius follows cornerRadius" "ib.radius.tracks" "9"
qp_assert "and the chrome follows too" "ib.radius.tracksChrome" "9"
qp_assert "changing cornerRadius moves radius" "ib.radius.afterChange" "3"
qp_assert "and the chrome with it" "ib.radius.afterChangeChrome" "3"

# ---------------------------------------------------------------------------
t_section "IconButton: a real tween, sampled in flight"
# forceHover moves the ground from transparent to the hover wash, and the
# chrome tweens through ColorAnim toward it. The ground is the target; the
# chrome is what moves when the global motion policy allows it.
qp_assert "the global motion switch follows policy" "ib.tween.motion" "$MOTION_ENABLED"
t_eq "the chrome starts transparent" "#00000000" "$(qp_get ib.tween.start)"
qp_assert "the derived slot is the token, clamped" "ib.mode.tokenMatches" "true"
t_eq "and the ground is already the target" "$(qp_get expect.fg012)" "$(qp_get ib.tween.ground)"
t_eq "the target is foreground_1 at 0.12" "0.12156862745098039" "$(qp_get ib.tween.targetAlpha)"
qp_assert "forceHover really did make it hovered" "ib.tween.hovered" "true"
qp_assert "and the ground was the target throughout" "ib.tween.ground5" "$(qp_get expect.fg012)"
qp_assert "the chrome lands exactly on the target" "ib.tween.landedIsTarget" "true"
t_eq "at the target's alpha" "0.12156862745098039" "$(qp_get ib.tween.landedAlpha)"
qp_assert "releasing forceHover puts the ground back" "ib.tween.releasedHovered" "false"
t_eq "to transparent" "#00000000" "$(qp_get ib.tween.releasedColor)"
if [[ $MOTION_ENABLED == "true" ]]; then
  t_match "the chrome is a real ARGB colour mid-flight" '^#[0-9a-f]{8}$' "$(qp_get ib.tween.mid5)"
  t_ne "one turn in, it is neither the start nor the target" "#00000000" "$(qp_get ib.tween.mid5)"
  t_ne "nor the target" "$(qp_get expect.fg012)" "$(qp_get ib.tween.mid5)"
  t_ne "two turns in it has moved again" "$(qp_get ib.tween.mid5)" "$(qp_get ib.tween.mid6)"
  t_ne "and three turns in again" "$(qp_get ib.tween.mid6)" "$(qp_get ib.tween.mid7)"
  lt "climbing monotonically" "$(qp_get ib.tween.mid5Alpha)" "$(qp_get ib.tween.mid7Alpha)"
  lt "and still short of the target" "$(qp_get ib.tween.mid7Alpha)" "$(qp_get ib.tween.targetAlpha)"
else
  t_skip "IconButton tween samples" "MotionPolicy.enabled is false, so the color change correctly snaps to its target"
fi

# ---------------------------------------------------------------------------
t_section "dimTiers: how many tier groups stay in body tone"
# The rule is Icons.recolor (Icons.qml:255-260): dimTiers 0 paints the whole
# glyph, and every tier-N with N > dimTiers drops to the ghost tone. The
# probe decodes the recolored SVG and lists the tier groups that came out
# ghosted, so this is a measurement of the artwork.
qp_assert "the icon scan landed" "ic.ready" "true"
qp_assert "and was still landed at the end of the run" "ic.readyFinal" "true"
t_match "and indexed the shipped set" '^[1-9][0-9][0-9]*$' "$(qp_get ic.indexed)"
t_match "the ghost tone is a real 6-digit hex" '^#[0-9a-f]{6}$' "$(qp_get ic.ghostTone)"
# volume-max carries tier-1..3.
t_empty "0 dims nothing" "$(qp_get ic.vol.tier0)"
t_eq "1 dims tiers 2 and 3" "2,3" "$(qp_get ic.vol.tier1)"
t_eq "2 dims tier 3" "3" "$(qp_get ic.vol.tier2)"
t_empty "3 dims nothing" "$(qp_get ic.vol.tier3)"
t_empty "a value past the last tier dims nothing" "$(qp_get ic.vol.tier4)"
t_empty "and a large one dims nothing" "$(qp_get ic.vol.tier9)"
t_eq "a negative value dims every tier" "1,2,3" "$(qp_get ic.vol.tier-1)"
t_count "which is all three of them" "3" "$(qp_get ic.vol.tier-1 | tr ',' '\n' | wc -l)"
# wifi-3 carries tier-1..4, the same rule one group deeper.
t_empty "0 dims nothing" "$(qp_get ic.wifi.tier0)"
t_eq "1 dims tiers 2 to 4" "4,3,2" "$(qp_get ic.wifi.tier1)"
t_eq "2 dims tiers 3 and 4" "4,3" "$(qp_get ic.wifi.tier2)"
t_empty "4 dims nothing" "$(qp_get ic.wifi.tier4)"
t_note "dimTiers has no clamp: a negative value dims every tier, because the rule
is dim !== 0 and N > dim (Icons.qml:258), and every N is greater than a negative
dim. IconButton forwards dimTiers unvalidated (IconButton.qml:156), so a caller
that computed a negative level would render a fully ghosted glyph rather than a
fully solid one. Pinned here as measured behaviour, not as a recommendation"
# The forwarded end: IconButton hands the value to its Icon, and the Icon hands
# it to Icons.url, so the artwork on the two buttons has to differ.
qp_assert "a tier-0 button paints the tier-0 artwork" "ic.forward.zero" "true"
qp_assert "a tier-1 button paints the tier-1 artwork" "ic.forward.one" "true"
qp_assert "which are different artwork" "ic.forward.differs" "true"
qp_assert "a flat button forwards its tiers too" "ic.forward.flatTwo" "true"
qp_assert "and the same tier twice is the same artwork" "ic.forward.sameTierSameArt" "true"

# ---------------------------------------------------------------------------
t_section "the components themselves, and the expressions the probe measured"
# The probe measured behaviour; these pin the expressions that produced it, so
# an edit that keeps the behaviour and breaks the contract is still caught.
t_file "IslandHost is where the suite says it is" "$ISLAND_HOST"
t_file "IconButton is where the suite says it is" "$ICON_BUTTON"
t_file "and the footprint store it delegates to" "$FROZEN_FOOTPRINT"
t_contains "the footprint bound is the literal this suite assumes" \
  "readonly property int frozenCapacity: 32" "$(<"$ISLAND_HOST")"
t_contains "isOpenFor compares the anchor object, not the key" \
  "return root.open && root.anchorItem === anchor" "$(<"$ISLAND_HOST")"
t_contains "the key is derived from the anchor's moduleId" \
  "anchor && anchor.moduleId !== undefined" "$(<"$ISLAND_HOST")"
t_contains "the footprint write is the copy-on-write store" \
  "root._footprint = saved.store" "$(<"$ISLAND_HOST")"
t_contains "hovered is gated on live" \
  "readonly property bool hovered: (btn.hovered || root.forceHover) && root.live" \
  "$(<"$ICON_BUTTON")"
t_contains "pressed is gated on live too" \
  "readonly property bool pressed: btn.pressed && root.live" "$(<"$ICON_BUTTON")"
t_contains "and live is the conjunction of the two gates" \
  "readonly property bool live: root.enabled && root.actionable" "$(<"$ICON_BUTTON")"
t_contains "the native control is gated on the hard lock alone" \
  "enabled: root.enabled" "$(<"$ICON_BUTTON")"
t_contains "the bright rung is the accent at 0.15" \
  'root.bright || root.pressed ? Ui.tint("accent", 0.15)' "$(<"$ICON_BUTTON")"
t_contains "radius is an alias, not a second knob" \
  "property real radius: root.cornerRadius" "$(<"$ICON_BUTTON")"

# ---------------------------------------------------------------------------
t_section "not reachable from here, and not claimed"
t_skip "the layer-shell window itself" \
  "no PanelWindow backend under QT_QPA_PLATFORM=offscreen: IslandHost cannot be constructed as written, and the headless rewrite cannot stand in for mapping, layershell state or exclusive-zone negotiation"
t_skip "the compositor focus grab" \
  "HyprlandFocusGrab.onCleared calls close() and only a live Hyprland can raise it; the block is removed from the evaluated text precisely so this suite never dispatches one"
t_skip "ESC and outside-click dismissal" \
  "the FocusScope and the MouseArea are in the evaluated text but need real key and pointer input, which needs a window"
t_skip "a real press, hover or keyboard focus" \
  "AbstractButton.pressed and .hovered are read-only and set by platform input handling; forceActiveFocus() is accepted but does nothing without a window, so _focused is only observable at its resting value"
t_skip "the tip bubble" \
  "_syncTip is gated on the native hovered, so the 350ms timer can never be reached headlessly; only the resting hidden state is asserted"
t_skip "second-output anchoring" \
  "the shell README records that a second output cannot be created here, so only the single virtual screen's code paths are exercised"
t_skip "the HyprlandFocusGrab window list contents" \
  "grabWindows() is pure and asserted (1 without a bar window, 2 with one), but what the compositor does with that list is not"

t_summary
