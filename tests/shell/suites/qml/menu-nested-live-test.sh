#!/bin/bash
# Suite: menu-nested-live - nested row behaviour on the running shell.
#
# These are behaviours a headless probe cannot see: a reveal seat is owned by
# the panel and the list together, Escape chooses a layer from live cursor
# state, and a staged swap changes the loader content while the slot is open.
# The suite drives the systemd shell through its menu IPC verbs and reads the
# panel's own probe back, so the assertion is on the geometry the user sees.
#
# The suite is skipped when the shell service is not up: it must never start a
# standalone qs process for a test, and it must never be counted as a pass when
# it did not exercise the live shell.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "menu-nested-live" "reveal restore, layered Escape and staged swaps on the live shell"

if ! command -v qs >/dev/null 2>&1; then
  t_block "qs is not on PATH"
fi
if [[ $(systemctl --user is-active vibranium-shell 2>/dev/null) != active ]]; then
  t_block "vibranium-shell.service is not active"
fi

FIXTURE="$VIBRANIUM_DIR/tests/shell/demos/nested-rows-showcase.jsonc"
if [[ ! -f $FIXTURE ]]; then
  t_block "the nested-rows stress fixture is missing: $FIXTURE"
fi

p() { qs -p "$VIBRANIUM_DIR/shell" ipc call menu "$@"; }

# probe_field <python-expression over d>
probe_field() {
  p probe | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null
}

open_fixture() {
  local file=${1:-$FIXTURE}
  p close >/dev/null 2>&1
  p openFile "$file" >/dev/null 2>&1
  sleep 0.6
}

# Restore the shell to the state this suite found it in. The verb set survives
# a menu close; the trace gates are explicitly turned off either way.
cleanup() {
  p debugTrace off >/dev/null 2>&1
  p close >/dev/null 2>&1
}
trap cleanup EXIT

# --- 1. a page row's reveal is restored on the fold, not on focus movement --

t_section "page-row reveal restore"
open_fixture
p debugSetCurrentIdx 6 >/dev/null 2>&1
sleep 0.3
pre="$(probe_field 'd["contentY"]')"
p debugActivatePanel >/dev/null 2>&1
sleep 0.8
open="$(probe_field 'd["contentY"]')"
p debugEscape >/dev/null 2>&1
sleep 1.0
closed="$(probe_field 'd["contentY"]')"

t_ne "the open reveals the row (contentY moves)" "$pre" "$open"
t_eq "the collapse restores the pre-open offset" "$pre" "$closed"

# --- 2. Escape peels nested layers one at a time ----------------------------

t_section "layered Escape in a deep group"
open_fixture
p debugSetCurrentIdx 10 >/dev/null 2>&1
sleep 0.3
for _ in 1 2 3 4; do
  p debugActivatePanel >/dev/null 2>&1
  sleep 0.5
done
tree_rows="$(probe_field 'd["childExpandH"]')"
p debugEscape >/dev/null 2>&1
sleep 0.8
one_rows="$(probe_field 'd["childExpandH"]')"
p debugEscape >/dev/null 2>&1
sleep 0.8
two_rows="$(probe_field 'd["childExpandH"]')"

t_ne "the deepest layer closes first" "$tree_rows" "$one_rows"
t_ne "the next layer closes on the next Escape" "$one_rows" "$two_rows"
t_eq "the toplevel group is still open after two Escapes" "True" \
  "$(probe_field 'd["dropdownOpen"]')"

# --- 3. a staged swap keeps the row open and lands on the next stage -------

t_section "staged flow swap"
open_fixture
# Flow cursors live outside the row state map and survive a menu close, so a
# fixture run must start from stage zero explicitly.
p debugResetFlow >/dev/null 2>&1
sleep 0.3
p debugSetCurrentIdx 8 >/dev/null 2>&1
sleep 0.3
p debugActivatePanel >/dev/null 2>&1
sleep 0.7
for _ in 1 2 3 4 5; do
  p debugChildMove 1 >/dev/null 2>&1
  sleep 0.08
done
p debugActivatePanel >/dev/null 2>&1
sleep 0.8
stage0="$(probe_field 'd["childExpandH"]')"
flow0="$(probe_field 'd["childFlowIdx"]')"
p debugKey returnKey >/dev/null 2>&1
sleep 0.8
stage1="$(probe_field 'd["childExpandH"]')"
flow1="$(probe_field 'd["childFlowIdx"]')"

t_eq "the group stays open across the stage swap" "True" \
  "$(probe_field 'd["childExpanded"]')"
t_ne "the stage content height changes" "$stage0" "$stage1"
t_eq "the editor stage is shorter than the option stage" "True" \
  "$(python3 -c "print($stage1 < $stage0)")"

# Enter on an open editor commits it, including when the key reaches the row
# through the group's pickCurrent() path, and advances to the next stage.
p debugKey returnKey >/dev/null 2>&1
sleep 0.8
flow2="$(probe_field 'd["childFlowIdx"]')"
t_eq "the second accept keeps the row open" "True" \
  "$(probe_field 'd["childExpanded"]')"
t_eq "the first accept moves to stage one" "1" "$flow1"
t_eq "the second accept moves to stage two" "2" "$flow2"
t_eq "the flow really started at stage zero" "0" "$flow0"

p debugKey returnKey >/dev/null 2>&1
sleep 0.9
t_eq "the last accept commits and folds the row" "False" \
  "$(probe_field 'd["childExpanded"]')"
p debugActivatePanel >/dev/null 2>&1
sleep 0.9
t_eq "a fresh open starts from the first stage" "$stage0" \
  "$(probe_field 'd["childExpandH"]')"

# --- 4. the panel resizes in step with a nested fold -----------------------
#
# The panel region follows the nested row's live height, so the window grows
# and folds with the dropdown. This fixture has a short group with a tall
# nested child, so the slot claim actually grows the panel. The gap between
# card height and row height is chrome; it stays constant in both directions.

t_section "panel height follows nested content"
open_fixture "$VIBRANIUM_DIR/tests/shell/demos/panel-grow.jsonc"
rest_card="$(probe_field 'd["geom"]["cardH"]')"
p debugSetCurrentIdx 1 >/dev/null 2>&1
sleep 0.3
p debugActivatePanel >/dev/null 2>&1
sleep 0.9
chrome="$(probe_field 'd["geom"]["cardH"] - d["rowH"]')"
for _ in 1 2 3 4; do
  p debugChildMove 1 >/dev/null 2>&1
  sleep 0.06
done
p debugActivatePanel >/dev/null 2>&1
# Sample through the unfold; a lagging region shows up as a changing gap.
worst=0
for _ in 1 2 3 4 5 6 7 8; do
  gap="$(probe_field 'd["geom"]["cardH"] - d["rowH"]')"
  diff="$(python3 -c "print(abs($gap - $chrome))")"
  if python3 -c "exit(0 if $diff > $worst else 1)"; then worst=$diff; fi
done
t_eq "the card stays chrome taller than the row while unfolding" "True" \
  "$(python3 -c "print($worst < 1.0)")"

sleep 0.9
p debugEscape >/dev/null 2>&1
worst=0
for _ in 1 2 3 4 5 6 7 8; do
  gap="$(probe_field 'd["geom"]["cardH"] - d["rowH"]')"
  diff="$(python3 -c "print(abs($gap - $chrome))")"
  if python3 -c "exit(0 if $diff > $worst else 1)"; then worst=$diff; fi
done
t_note "collapse gap: chrome=$chrome worst=$worst"
t_eq "and through the fold back" "True" \
  "$(python3 -c "print($worst < 1.0)")"

# The resting list carries the outer padding, so a live row is shorter than
# the resting size. The card never drops below that floor during a close.
p debugEscape >/dev/null 2>&1
lowest=99999
for _ in 1 2 3 4 5 6 7 8; do
  card="$(probe_field 'd["geom"]["cardH"]')"
  if python3 -c "exit(0 if $card < $lowest else 1)"; then lowest=$card; fi
done
t_eq "a toplevel close never shrinks past the resting card" "True" \
  "$(python3 -c "print($lowest >= $rest_card - 1)")"

# --- 5. a nested close keeps its content mounted through the fade ----------

t_section "nested close does not rebuild its view"
open_fixture
p debugSetCurrentIdx 8 >/dev/null 2>&1
sleep 0.3
p debugActivatePanel >/dev/null 2>&1
sleep 0.7
p debugActivatePanel >/dev/null 2>&1
sleep 0.8
builds_open="$(probe_field 'd["childBuilds"]')"
p debugEscape >/dev/null 2>&1
sleep 0.9
builds_closed="$(probe_field 'd["childBuilds"]')"
t_eq "closing a nested dropdown does not rebuild its options" "$builds_open" \
  "$builds_closed"

# --- 6. a held key keeps the cursor dead centre ----------------------------
#
# A repeated ease restarts at zero velocity. Auto-repeat steps land their seat
# so the cursor holds the centre through the whole hold.

t_section "centre lock under auto-repeat"
open_fixture
p debugSetCurrentIdx 4 >/dev/null 2>&1
sleep 0.4
for _ in 1 2 3 4; do
  p debugAutoMove 1 >/dev/null 2>&1
done
off="$(probe_field 'd["curY"] + d["curH"] / 2 - d["contentY"] - d["geom"]["listH"] / 2')"
t_eq "the cursor stays near the centre through a held key" "True" \
  "$(python3 -c "print(abs($off) < 15)")"

# --- 7. the push, column shift and box share one progress -------------------
#
# The neighbour slide, column shift and box growth each scale one fraction of
# their destination, so they start and land with the same motion.

t_section "one progress for the nested push"
open_fixture
p debugSetCurrentIdx 10 >/dev/null 2>&1
sleep 0.3
p debugActivatePanel >/dev/null 2>&1
sleep 0.8
p debugActivatePanel >/dev/null 2>&1
sleep 0.9
prog="$(probe_field 'd["pushProg"]')"
box="$(probe_field 'd["boxNeed"]')"
target="$(probe_field 'd["boxTarget"]')"
t_eq "box growth is progress times its destination" "True" \
  "$(python3 -c "print(abs($box - $prog * $target) < 1)")"

# --- 8. a cursor step during the fold cannot steal the restore -------------
#
# The close restore tracks the row that is folding. A step taken mid-fold
# moves the cursor to another row, and the seat must still follow the closing
# row instead of jumping to the origin in one frame.

t_section "interrupted close restores smoothly"
open_fixture
p debugSetCurrentIdx 8 >/dev/null 2>&1
sleep 0.3
origin="$(probe_field 'd["contentY"]')"
p debugActivatePanel >/dev/null 2>&1
sleep 0.8
p debugActivatePanel >/dev/null 2>&1
sleep 0.8
p debugEscape >/dev/null 2>&1
sleep 0.9
p debugEscape >/dev/null 2>&1
p debugKey down >/dev/null 2>&1
sleep 1.0
t_eq "a step during the fold lands on the pre-open offset" "$origin" \
  "$(probe_field 'd["contentY"]')"

# --- 9. the "/" filter reaches nested children and restores the open group --

t_section "scoped filter over nested rows"
open_fixture
p debugSetCurrentIdx 6 >/dev/null 2>&1
sleep 0.3
p debugActivatePanel >/dev/null 2>&1
sleep 0.8
open_child="$(probe_field 'd["childLabel"]')"

# "Signal strength" lives inside the Devices group, not on the page's own row
# set. A page-only filter answers "No matches"; a tree-aware one keeps the
# group and narrows its child list to the matching branch.
p debugBeginScoped >/dev/null 2>&1
sleep 0.3
p debugType signal >/dev/null 2>&1
sleep 0.7
t_eq "a child label is filterable" "1" "$(probe_field 'd["count"]')"
t_eq "the group is the result, not a detached child" "group" \
  "$(probe_field 'd["rowType"]')"
t_eq "the cursor stays on the top result" "0" "$(probe_field 'd["index"]')"
t_eq "the group's children are narrowed" "1" "$(probe_field 'd["grpChildCount"]')"
t_eq "the filter's bar matches the result row" "True" \
  "$(python3 -c "print(abs($(probe_field 'd["hlH"]') - $(probe_field 'd["curH"]')) < 1)")"

# Clearing the trim must give back the page seat: the group, its scroll
# offset, its focused child and the bar that is the slot's background.
p debugEscape >/dev/null 2>&1
sleep 1.0
t_eq "the group is still open" "True" "$(probe_field 'd["dropdownOpen"]')"
t_eq "its expansion survives the filter" "True" "$(probe_field 'd["expanded"]')"
t_eq "the focused child is restored" "$open_child" "$(probe_field 'd["childLabel"]')"
t_eq "the whole child list is restored" "7" "$(probe_field 'd["grpChildCount"]')"
t_eq "the reveal claim is restored" "6" "$(probe_field 'd["autoRevealIndex"]')"
exit_y="$(probe_field 'd["contentY"]')"
t_eq "the restored row is on screen" "True" \
  "$(python3 -c "print(0 <= $(probe_field 'd["hlY"]') < $(probe_field 'd["geom"]["listH"]'))")"
t_eq "the selection bar is visible" "True" "$(probe_field 'd["hlVisible"]')"
t_eq "the bar covers the expanded group" "True" \
  "$(python3 -c "print(abs($(probe_field 'd["hlH"]') - $(probe_field 'd["curH"]')) < 1)")"

# And the restored view still navigates: a step moves the nested child without
# collapsing the group or dragging the viewport.
p debugChildMove 1 >/dev/null 2>&1
sleep 0.4
t_ne "the nested cursor moves after the restore" "$open_child" \
  "$(probe_field 'd["childLabel"]')"
t_eq "the group stays open through the step" "True" \
  "$(probe_field 'd["dropdownOpen"]')"
t_eq "the scroll holds through the step" "$exit_y" "$(probe_field 'd["contentY"]')"

t_summary
