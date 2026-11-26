#!/bin/bash
# Suite: menu-nested-live - nested row behavior on the running shell.
#
# These are behaviors a headless probe cannot see: a reveal seat is owned by
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

# Serialise against the other live menu suites: they all drive one shell.
MENU_LIVE_LOCK="${TMPDIR:-/tmp}/vb-menu-live.lock"
exec 9>"$MENU_LIVE_LOCK"
flock -w 600 9 || t_block "could not acquire the menu live lock"

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

# The resident panel's deep sampler records a frame every 16 ms in shell time.
# Reading the finished array in one reply keeps consecutive-frame assertions
# independent of how long an external `qs ipc call` round trip takes.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-menu-nested.XXXXXX")"

collect_deep() {
  local out="$1" off=0 take=8 chunk
  : >"$out"
  while :; do
    chunk="$(p probeDeep "$off" "$take" 2>/dev/null)"
    if ! printf '%s' "$chunk" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
      ((take > 1)) || return 1
      take=$((take / 2))
      continue
    fi
    [[ $chunk == '[]' ]] && break
    printf '%s\n' "$chunk" >>"$out"
    off=$((off + take))
  done
}

deep_motion() {
  python3 - "$@" <<'PY'
import json, sys
for path in sys.argv[1:]:
    for line in open(path):
        for f in json.loads(line):
            b = f["base"]
            print(b["contentY"], b["animRunning"], b["hlMoveMs"],
                  b["seatsInstant"], b["followIdx"], b["index"])
PY
}

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
  p debugDeep off >/dev/null 2>&1
  p close >/dev/null 2>&1
  rm -rf "$WORK"
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
t_eq "the stage description grows the editor stage" "True" \
  "$(python3 -c "print($stage1 > $stage0)")"
# The outgoing option list is frozen for its slide-fade. It must keep the
# stage's own options, not fall back to the row's plain "Legacy option" when
# the next stage has no option list of its own.
t_eq "the ghost holds the outgoing stage's options" "One|Two" \
  "$(probe_field 'd["childGhostLabels"]')"

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

# The nested cursor bar belongs to the dropdown body: when the group folds it
# must fade out with the content, not blink off on the frame `expanded` drops.
# Escape collapses the group while its internal cursor still points at a child.
t_section "the nested cursor fades with the collapse"
open_fixture
p debugSetCurrentIdx 8 >/dev/null 2>&1
sleep 0.3
p debugActivatePanel >/dev/null 2>&1
sleep 0.7
t_eq "the group cursor is painted while open" "True" \
  "$(probe_field 'd["grpBarVisible"]')"
t_eq "and fully opaque" "1" "$(probe_field 'd["grpBarOpacity"]')"
p debugEscape >/dev/null 2>&1
# First read lands while the slot is still folding: the bar must still paint.
t_eq "the cursor stays painted into the fold" "True" \
  "$(probe_field 'd["grpBarVisible"]')"
sleep 0.6
t_eq "and is gone once the fold lands" "False" \
  "$(probe_field 'd["grpBarVisible"]')"

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
# set. The filter flattens the matching descendant into a regular top-level
# result row - the same visual language as global search - instead of showing
# the owning group. Selecting it still lands in the group's real nesting.
p debugBeginScoped >/dev/null 2>&1
sleep 0.3
p debugType signal >/dev/null 2>&1
sleep 0.7
t_eq "a nested child is filterable" "1" "$(probe_field 'd["count"]')"
t_eq "the hit is a flat result row" "result" \
  "$(probe_field 'd["rowType"]')"
t_eq "the result shows the child, not its group" "Signal strength" \
  "$(probe_field 'd["rowLabel"]')"
t_eq "the cursor stays on the top result" "0" "$(probe_field 'd["index"]')"
t_eq "no group chrome sits in the flat result" "0" \
  "$(probe_field 'd["grpChildCount"]')"
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

# --- 10. a search hit owned by the CURRENT page still unfolds its group -----

t_section "search-result landing on the current page"
open_fixture
# "Signal strength" lives inside the Devices group on this very page. The
# landing must still consume its pending seat here: no page change means no
# onCurrentPageIdChanged install to hand the seat over, so an unconsumed
# pendingSel leaves every settled waiter gated off and the group folded.
p debugType signal >/dev/null 2>&1
sleep 0.7
t_eq "the hit is a search result" "result" "$(probe_field 'd["rowType"]')"
p debugActivatePanel >/dev/null 2>&1
sleep 1.2
t_eq "the landing stays on the hit's page" "nested-showcase" \
  "$(probe_field 'd["page"]')"
t_eq "the owning group opens" "True" \
  "$(probe_field 'd["dropdownOpen"]')"
t_eq "the matching child is seated" "Signal strength" \
  "$(probe_field 'd["childLabel"]')"

# --- 11. an input hit lands focused, not open -------------------------------

t_section "search-result landing on input rows"
# "Time format" is a direct select row on General, not a group child. The hit
# names the row, so arrival must leave it current with its dropdown folded;
# the option is opened by the next Enter, like any browsed row.
p close >/dev/null 2>&1
p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#main" >/dev/null 2>&1
sleep 0.7
p debugType "time format" >/dev/null 2>&1
sleep 0.6
p debugActivatePanel >/dev/null 2>&1
sleep 1.2
t_eq "a select hit lands on its page" "general" "$(probe_field 'd["page"]')"
t_eq "the select row is current" "select" "$(probe_field 'd["rowType"]')"
t_eq "its dropdown stays folded" "False" \
  "$(probe_field 'd["dropdownOpen"]')"
p debugActivatePanel >/dev/null 2>&1
sleep 0.7
t_eq "a second Enter opens the select" "True" \
  "$(probe_field 'd["dropdownOpen"]')"

# A number/range hit used to open its editor on arrival for the same reason.
p close >/dev/null 2>&1
p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#main" >/dev/null 2>&1
sleep 0.7
p debugType "brightness step" >/dev/null 2>&1
sleep 0.6
p debugActivatePanel >/dev/null 2>&1
sleep 1.2
t_eq "a number hit lands on its page" "brightness" \
  "$(probe_field 'd["page"]')"
t_eq "the range row is current" "range" "$(probe_field 'd["rowType"]')"
t_eq "its editor stays closed" "False" \
  "$(probe_field 'd["editorOpen"]')"

# --- 12. a deep nested close keeps the page scroll it landed on -------------

t_section "nested close keeps the page scroll"
# "Heavy backlog warning" is two groups deep on the bar page. Its landing
# reveal scrolls the top-level list; the nested fold must not undo that
# scroll and leave the fit to correct it on the next frame.
p close >/dev/null 2>&1
p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#main" >/dev/null 2>&1
sleep 0.7
p debugType "heavy warning" >/dev/null 2>&1
sleep 0.6
p debugActivatePanel >/dev/null 2>&1
sleep 1.3
t_eq "the deep hit lands on its page" "bar" "$(probe_field 'd["page"]')"
landed="$(probe_field 'd["contentY"]')"
p debugEscape >/dev/null 2>&1
sleep 0.18
mid="$(probe_field 'd["contentY"]')"
sleep 0.18
t_eq "the nested fold does not yank the page scroll" "$landed" "$mid"
t_eq "and the scroll holds through the fold" "$landed" \
  "$(probe_field 'd["contentY"]')"
sleep 0.4
t_eq "the nested group folded" "False" \
  "$(probe_field 'd["childExpanded"]')"

# --- 13. a programmatic 1 -> 7 jump seats through the page ------------------
#
# The IPC verb used to write currentIndex raw, so a jump teleported in one
# frame with no scroll and no bar glide. It now delegates to the panel's seat
# path, which gives it the same reveal as repeated debugAutoMove steps. Sample
# consecutive probe frames, not a resting value after a sleep.

# One snapshot -> contentY animRunning hlMoveMs seatsInstant followIdx index.
probe_motion() {
  p probe | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['contentY'], d['animRunning'], d['hlMoveMs'], d['seatsInstant'], d['followIdx'], d['index'])" 2>/dev/null
}

# motion_metrics <samples> -> animFrames cySpan hlMoveMax instantFrames followMax cyLast lastIdx
motion_metrics() {
  printf '%s\n' "$1" | python3 -c '
import sys
rows = []
for line in sys.stdin:
    f = line.split()
    if len(f) != 6:
        continue
    rows.append((float(f[0]), f[1] == "True", int(f[2]), f[3] == "True", int(f[4]), int(f[5])))
if not rows:
    print(0, 0, 0, 0, -1, 0, -1)
else:
    ys = [r[0] for r in rows]
    print(sum(1 for r in rows if r[1]),
          round(max(ys) - min(ys), 1),
          max(r[2] for r in rows),
          sum(1 for r in rows if r[3]),
          max(r[4] for r in rows),
          round(ys[-1], 1),
          rows[-1][5])
'
}

t_section "programmatic jump seats through the page"
open_fixture
p debugSetCurrentIdx 1 >/dev/null 2>&1
sleep 0.6
t_eq "the jump starts at index one" "1" "$(probe_field 'd["index"]')"

# The verb under test: one 1 -> 7 jump, sampled across consecutive frames.
# Sampling now happens inside the resident panel, so a slow IPC round trip can
# no longer swallow the 120 ms animation. The six values and every assertion
# below are the same as before.
p debugDeep on >/dev/null 2>&1
p debugSetCurrentIdx 7 >/dev/null 2>&1
sleep 0.4
p debugDeep off >/dev/null 2>&1
collect_deep "$WORK/programmatic.jsonl"
prog_samples="$(deep_motion "$WORK/programmatic.jsonl")"
read -r p_anim p_span p_hl p_inst p_follow p_cy p_idx \
  <<<"$(motion_metrics "$prog_samples")"

t_eq "the jump lands on index seven" "7" "$p_idx"
t_eq "the jump animates across consecutive frames" "True" \
  "$(python3 -c "print($p_anim >= 2)")"
t_eq "contentY changes across the frames" "True" \
  "$(python3 -c "print($p_span > 5)")"
t_eq "no frame takes an instant seat" "0" "$p_inst"
t_eq "the seat follows index seven" "7" "$p_follow"
t_eq "a highlight sweep is armed" "True" \
  "$(python3 -c "print($p_hl > 0)")"

# The same 1 -> 7 jump driven by the browsed step path. Non-selectable rows
# are skipped, so step until the probe reaches 7, probing each leg.
p debugSetCurrentIdx 1 >/dev/null 2>&1
sleep 0.6
auto_samples=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  p debugAutoMove 1 >/dev/null 2>&1
  frame="$(probe_motion)"
  auto_samples+="$frame"$'\n'
  read -r _cy _anim _hl _inst _follow a_idx <<<"$frame"
  [[ $a_idx == 7 ]] && break
done
for _ in 1 2 3 4 5; do
  auto_samples+="$(probe_motion)"$'\n'
done
read -r a_anim a_span a_hl a_inst a_follow a_cy a_idx \
  <<<"$(motion_metrics "$auto_samples")"

t_eq "the browsed steps reach index seven" "7" "$a_idx"
t_eq "the browsed path shows no instant seats" "0" "$a_inst"
t_eq "both paths land on the same row" "$p_idx" "$a_idx"
t_eq "both paths arm a cursor follow" "True" \
  "$(python3 -c "print($p_follow >= 0 and $a_follow >= 0)")"
t_eq "both paths land on the same offset" "True" \
  "$(python3 -c "print(abs($p_cy - $a_cy) < 3)")"
t_eq "both paths arm a highlight sweep" "True" \
  "$(python3 -c "print($p_hl > 0 and $a_hl > 0)")"
t_eq "the browsed path also scrolls over frames" "True" \
  "$(python3 -c "print($a_span > 5)")"

# --- 14. a scoped result re-derives the reveal claim on the restored page ---

t_section "scoped result keeps the page claim"
# A filtered group opens while it still carries the trimmed index. The full
# rows come back underneath it; the reveal claim must be re-derived against
# them or pursuit keeps fighting the page's scroll and fit.
p close >/dev/null 2>&1
p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#main" >/dev/null 2>&1
sleep 0.7
p debugSetCurrentIdx 0 >/dev/null 2>&1
sleep 0.2
p debugActivatePanel >/dev/null 2>&1
sleep 0.5
status_idx=$(p debugRows | python3 -c 'import json,sys; print(next((i for i,r in enumerate(json.load(sys.stdin)) if r["label"]=="Statusbar"),-1))')
p debugSetCurrentIdx "$status_idx" >/dev/null 2>&1
sleep 0.2
p debugActivatePanel >/dev/null 2>&1
sleep 0.6
p debugBeginScoped >/dev/null 2>&1
sleep 0.3
p debugType backlog >/dev/null 2>&1
sleep 0.6
t_eq "the filter flattens the nested hit" "result" "$(probe_field 'd["rowType"]')"
t_eq "the flat result is the matching child" "Heavy backlog warning" \
  "$(probe_field 'd["rowLabel"]')"
p debugActivatePanel >/dev/null 2>&1
sleep 1.2
landed_idx="$(probe_field 'd["index"]')"
t_eq "the reveal claim follows the landed row" "$landed_idx" \
  "$(probe_field 'd["autoRevealIndex"]')"
t_eq "the page reveals the open slot" "True" \
  "$(python3 -c "print($(probe_field 'd["contentY"]') > 0)")"
t_eq "the group has its full child list back" "8" \
  "$(probe_field 'd["grpChildCount"]')"

# --- 15. a two-level filter hit lands flat, then unfolds its real nesting ----

t_section "scoped flat result unfolds on selection"
p close >/dev/null 2>&1
p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#main" >/dev/null 2>&1
sleep 0.7
p debugSetCurrentIdx 0 >/dev/null 2>&1
sleep 0.2
p debugActivatePanel >/dev/null 2>&1
sleep 0.5
general_idx=$(p debugRows | python3 -c 'import json,sys; print(next((i for i,r in enumerate(json.load(sys.stdin)) if r["label"]=="General"),-1))')
p debugSetCurrentIdx "$general_idx" >/dev/null 2>&1
sleep 0.2
p debugActivatePanel >/dev/null 2>&1
sleep 0.6
p debugBeginScoped >/dev/null 2>&1
sleep 0.3
p debugType "drop shadow" >/dev/null 2>&1
sleep 0.7
t_eq "one flat result" "1" "$(probe_field 'd["count"]')"
t_eq "the result is rendered as a row" "result" "$(probe_field 'd["rowType"]')"
t_eq "it shows the nested child" "Drop shadow" "$(probe_field 'd["rowLabel"]')"
# Sample the handoff itself. The border must stay painted (a string-typed
# palette colour used to make the blend transparent), and the card must grow
# monotonically (a stale filter height latch used to collapse it for frames).
p debugActivatePanel >/dev/null 2>&1
hand_samples=""
for _ in 1 2 3 4 5 6; do
  hand_samples+="$(p probe | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("fieldBorder"), d.get("geom",{}).get("cardH",0), d.get("handoff"))' 2>/dev/null)"$'\n'
  sleep 0.04
done
t_note "handoff samples: $(printf '%s\n' "$hand_samples" | tr '\n' '|')"
t_eq "the field border stays painted through the handoff" "True" \
  "$(printf '%s\n' "$hand_samples" | python3 -c 'import sys; rows=[l.split() for l in sys.stdin if l.strip() and len(l.split())==3]; print(all(r[0].lower() not in ("#00000000","#0000") for r in rows))')"
t_eq "the card never collapses during the handoff" "True" \
  "$(printf '%s\n' "$hand_samples" | python3 -c 'import sys; hs=[float(l.split()[1]) for l in sys.stdin if l.strip()]; print(all(b >= a - 1 for a,b in zip(hs,hs[1:])))')"
sleep 0.9
t_eq "it lands on the owning group" "group" "$(probe_field 'd["rowType"]')"
t_eq "the owning group is open" "True" "$(probe_field 'd["expanded"]')"
t_eq "the matching child is seated" "Drop shadow" \
  "$(probe_field 'd["childLabel"]')"
t_eq "the full child list is restored" "4" \
  "$(probe_field 'd["grpChildCount"]')"
t_eq "the reveal claim follows the landed row" "$(probe_field 'd["index"]')" \
  "$(probe_field 'd["autoRevealIndex"]')"
t_eq "the page revealed the open slot" "True" \
  "$(python3 -c "print($(probe_field 'd["contentY"]') > 0)")"

# --- 16. a filtered landing reveals the page like a manual expansion -------

t_section "filtered landing matches manual page scroll"
goto_general() {
  p close >/dev/null 2>&1
  p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#main" >/dev/null 2>&1
  sleep 0.7
  p debugSetCurrentIdx 0 >/dev/null 2>&1
  sleep 0.2
  p debugActivatePanel >/dev/null 2>&1
  sleep 0.5
  local gi
  gi=$(p debugRows | python3 -c 'import json,sys; print(next((i for i,r in enumerate(json.load(sys.stdin)) if r["label"]=="General"),-1))')
  p debugSetCurrentIdx "$gi" >/dev/null 2>&1
  sleep 0.2
  p debugActivatePanel >/dev/null 2>&1
  sleep 0.7
}
goto_general
mi=$(p debugRows | python3 -c 'import json,sys; print(next((i for i,r in enumerate(json.load(sys.stdin)) if r["label"]=="Menus"),-1))')
p debugSetCurrentIdx "$mi" >/dev/null 2>&1
sleep 0.2
p debugActivatePanel >/dev/null 2>&1
sleep 1.2
manual_y="$(probe_field 'd["contentY"]')"
goto_general
p debugBeginScoped >/dev/null 2>&1
sleep 0.2
p debugType "drop shadow" >/dev/null 2>&1
sleep 0.7
p debugActivatePanel >/dev/null 2>&1
filter_frames=""
for _ in 1 2 3 4 5 6 7 8; do
  filter_frames+="$(probe_field 'd["contentY"]')"$'\n'
  sleep 0.04
done
sleep 0.8
filter_y="$(probe_field 'd["contentY"]')"
t_note "manual=$manual_y filter=$filter_y frames=$(printf '%s\n' "$filter_frames" | tr '\n' '|')"
t_eq "the filtered landing uses the same page scroll" "True" \
  "$(python3 -c "print(abs($manual_y - $filter_y) < 3)")"
# The reveal is one motion: no frame may overshoot past the settled offset
# and then come back (the old path parked at the row top before correcting).
t_eq "no frame overshoots the reveal" "True" \
  "$(printf '%s\n' "$filter_frames" | python3 -c 'import sys; ys=[float(x) for x in sys.stdin if x.strip()]; print(all(y <= max(float(sys.argv[1]), 0) + 3 for y in ys))' "$manual_y")"
t_eq "the filtered landing seats the same child" "Drop shadow" \
  "$(probe_field 'd["childLabel"]')"

t_summary
