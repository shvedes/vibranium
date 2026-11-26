#!/bin/bash
# Suite: menu-lib-live - the deepest live trace of the menu demo.
#
# Two seeded walks (animations on, animations off) drive the nested-rows
# showcase through cursor moves, dropdowns of every kind, editors, number
# pickers, search and scoped filter. Before every step the panel marks the
# phase; a 16ms sampler records the whole visible row tree, the viewport,
# the card's reactive verdicts and the one handoff value for every frame.
#
# The assertions are on the trace, not on where a gesture happened to land:
# a row must stay within its live height transition, no group may leave content behind
# its bottom border, the card must derive from its own live chain on every
# frame, the highlight must stay inside the viewport and the four handoff
# presentations must stay functions of one number. Static expected values
# (child counts, seeded values) from the demo are checked whenever a row is
# seen. The raw trace is kept under /tmp/opencode for human inspection.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "menu-lib-live" "frame-level menu trace: two seeded walks, motion on and off"

# One resident shell is shared by every live menu suite. Serialise the live
# phase here so a concurrent suite cannot change the open bundle or the guard
# state under a sampling walk. This changes no assertion and no animation.
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
GROW_FIXTURE="$VIBRANIUM_DIR/tests/shell/demos/panel-grow.jsonc"
ANALYZER="$VIBRANIUM_DIR/tests/shell/demos/menu-lib-analyze.py"
if [[ ! -f $FIXTURE || ! -f $GROW_FIXTURE || ! -f $ANALYZER ]]; then
  t_block "the demo fixture or the trace analyzer is missing"
fi
if ! mkdir -p /tmp/opencode; then
  t_block "the trace directory could not be created"
fi

p() { qs -p "$VIBRANIUM_DIR/shell" ipc call menu "$@"; }

cleanup() {
  p debugDeep off >/dev/null 2>&1
  p restoreAnims >/dev/null 2>&1
  p debugTrace off >/dev/null 2>&1
  p close >/dev/null 2>&1
}
trap cleanup EXIT

WORDS=(device signal shadow theme color power guide branch body tail)
CHARS=(a s d f 1 2 0 space)

open_fixture() {
  local fixture=${1:-$FIXTURE}
  p close >/dev/null
  p openFile "$fixture" >/dev/null
  sleep 0.6
}

walk() {
  local mode=$1 sleep_s=$2 iterations=$3
  local trace="/tmp/opencode/menu-lib-trace-${mode}.json"
  local motion=off
  [[ $mode == animations ]] && motion=on
  p debugAnims "$motion" >/dev/null 2>&1
  open_fixture
  # Drain the panel's frame ring into one JSON array. The IPC reply is
  # size-limited, so use smaller chunks when nested rows make a frame larger.
  drain_trace() {
    local out=$1 off=0 chunk take=8
    local chunks="${out%.json}.jsonl"
    : > "$chunks"
    while :; do
      if ! chunk=$(p probeDeep "$off" "$take" 2>/dev/null) || [[ $chunk != \[* ]]; then
        ((take > 1)) || return 1
        take=$((take / 2))
        continue
      fi
      [[ $chunk == '[]' ]] && break
      printf '%s\n' "$chunk" >> "$chunks"
      off=$((off + take))
    done
    python3 - "$chunks" "$out" <<'PY'
import json
import sys
from pathlib import Path

chunks, out = map(Path, sys.argv[1:])
with chunks.open() as source, out.open("w") as trace:
    frames = [frame for line in source for frame in json.loads(line)]
    json.dump(frames, trace, separators=(",", ":"))
chunks.unlink()
if not 0 < len(frames) < 600:
    sys.exit(f"invalid capture size in {out}: {len(frames)} frames")
PY
  }

  local part="${trace%.json}"
  local -a parts=("${part}-census.json")
  p debugDeep on >/dev/null 2>&1
  # A deterministic census first: every top-level row becomes the cursor, so
  # the analyzer can check the static expected values even if the random walk
  # never visits some of them.
  local i
  for ((i = 0; i < 18; i++)); do
    p deepPhase "census-${i}" >/dev/null 2>&1
    p debugSetCurrentIdx "$i" >/dev/null 2>&1
    sleep "$sleep_s"
  done

  # The ring holds 600 frames (~10s). Each coverage window is recorded and
  # drained separately, so an early dropdown is not evicted by a late walk.
  p debugDeep off >/dev/null 2>&1
  drain_trace "${part}-census.json" || return 1

  # Deterministic dropdown coverage: every group gets opened, a child slot
  # gets expanded inside it, and the close is traced too. The random walk
  # alone can leave whole dropdown classes untouched in a short pass.
  for idx in 6 7 8 9 10 11 14; do
    open_fixture
    p debugDeep on >/dev/null 2>&1
    p deepPhase "open-group-${idx}" >/dev/null 2>&1
    p debugSetCurrentIdx "$idx" >/dev/null 2>&1
    sleep 0.2
    p debugActivatePanel >/dev/null 2>&1
    sleep "$sleep_s"
    p deepPhase "group-child-${idx}" >/dev/null 2>&1
    p debugChildMove 1 >/dev/null 2>&1
    p debugActivatePanel >/dev/null 2>&1
    sleep "$sleep_s"
    p deepPhase "close-group-${idx}" >/dev/null 2>&1
    p debugEscape >/dev/null 2>&1
    sleep "$sleep_s"
    p debugEscape >/dev/null 2>&1
    sleep "$sleep_s"
    p debugDeep off >/dev/null 2>&1
    parts+=("${part}-group-$idx.json")
    drain_trace "${part}-group-$idx.json" || return 1
  done

  # Targeted deep dropdowns: a number field, a staged select that swaps its
  # body, and an expandable description. These are the shapes where a slot
  # can leave content under its own bottom border or stall the card height.
  for target in "6 3 number" "8 5 flow" "9 0 body" "14 2 tail-select"; do
    set -- $target
    open_fixture
    p debugDeep on >/dev/null 2>&1
    p deepPhase "deep-$3" >/dev/null 2>&1
    p debugSetCurrentIdx "$1" >/dev/null 2>&1
    sleep 0.4
    p debugActivatePanel >/dev/null 2>&1
    sleep 0.5
    for ((k = 0; k < $2; k++)); do
      p debugChildMove 1 >/dev/null 2>&1
      sleep 0.15
    done
    p debugActivatePanel >/dev/null 2>&1
    sleep 0.6
    if [[ $3 == flow ]]; then
      p deepPhase "flow-next" >/dev/null 2>&1
      p debugKey returnKey >/dev/null 2>&1
      sleep 0.5
    fi
    if [[ $3 == number ]]; then
      p deepPhase "number-step" >/dev/null 2>&1
      p debugKey plus >/dev/null 2>&1
      sleep 0.3
    fi
    p deepPhase "deep-$3-close" >/dev/null 2>&1
    p debugEscape >/dev/null 2>&1
    sleep 0.4
    p debugEscape >/dev/null 2>&1
    sleep 0.4
    p debugDeep off >/dev/null 2>&1
    parts+=("${part}-$3.json")
    drain_trace "${part}-$3.json" || return 1
  done

  open_fixture "$GROW_FIXTURE"
  p debugDeep on >/dev/null
  p debugSetCurrentIdx 1 >/dev/null
  p debugActivatePanel >/dev/null
  sleep 0.6
  for ((k = 0; k < 4; k++)); do
    p debugChildMove 1 >/dev/null
  done
  p deepPhase grow-before >/dev/null
  sleep 0.2
  p deepPhase grow-open >/dev/null
  p debugActivatePanel >/dev/null
  sleep 0.7
  p deepPhase grow-fold >/dev/null
  p debugEscape >/dev/null
  sleep 0.7
  p debugDeep off >/dev/null
  parts+=("${part}-grow.json")
  drain_trace "${part}-grow.json" || return 1

  # A long page must fit the filtered row, then return to its full height
  # without publishing the destination ahead of the height animation. The
  # outgoing group is still folding when the search row arrives; its delegate
  # cannot reclaim the filtered card's height after the fit lands.
  open_fixture
  p debugSetCurrentIdx 6 >/dev/null
  p debugActivatePanel >/dev/null
  sleep 0.4
  p debugDeep on >/dev/null
  p deepPhase filter-shrink >/dev/null
  p debugSetQuery device >/dev/null
  sleep 0.5
  p deepPhase filter-restore >/dev/null
  p debugSetQuery "" >/dev/null
  sleep 0.5
  p debugDeep off >/dev/null
  local filter_trace="${part}-filter-fit.json"
  drain_trace "$filter_trace" || return 1
  python3 - "$filter_trace" "$motion" <<'PY' || return 1
import json, sys

frames = json.load(open(sys.argv[1]))
shrunk = [f for f in frames
          if f["phase"] == "filter-shrink" and f["base"]["count"] == 1]
restored = [f for f in frames
            if f["phase"] == "filter-restore" and f["base"]["count"] == 15]
if not shrunk or not restored or any(
        abs(group[-1]["card"]["rendered"] - group[-1]["base"]["tenRowH"]) > 2
        for group in (shrunk, restored)):
    sys.exit("filter fit did not reach the one-row and full-page heights")
if sys.argv[2] == "on":
    for group, direction in ((shrunk, -1), (restored, 1)):
        values = [f["card"]["rendered"] for f in group]
        if len(values) < 3 or any((b - a) * direction < -2
                                  for a, b in zip(values, values[1:])):
            sys.exit("filter height reversed or jumped during its resize")
PY

  # A nested dropdown is not a tall page: restoring it must follow the
  # group's unfolding slot, not a fit to the resting page rows.
  open_fixture "$GROW_FIXTURE"
  p debugSetCurrentIdx 1 >/dev/null
  p debugActivatePanel >/dev/null
  sleep 0.5
  p debugDeep on >/dev/null
  p deepPhase nested-filter >/dev/null
  p debugSetQuery "Child 4" >/dev/null
  sleep 0.5
  p deepPhase nested-restore >/dev/null
  p debugSetQuery "" >/dev/null
  sleep 0.6
  p debugDeep off >/dev/null
  local nested_trace="${part}-nested-filter-fit.json"
  drain_trace "$nested_trace" || return 1
  python3 - "$nested_trace" "$motion" <<'PY' || return 1
import json, sys

frames = json.load(open(sys.argv[1]))
filtered = [f for f in frames
            if f["phase"] == "nested-filter" and f["base"]["count"] == 1]
restored = [f for f in frames
            if f["phase"] == "nested-restore" and f["base"]["count"] == 2]
if not filtered or not restored:
    sys.exit("nested filter did not install both projections")
if abs(filtered[-1]["card"]["rendered"] - filtered[-1]["base"]["rowH"]) > 2:
    sys.exit("nested result did not fit one row")
def group(frame):
    return next((r for r in frame["rows"] if r["label"] == "Top group"), None)
last = group(restored[-1])
if not last or not last["expanded"] or abs(restored[-1]["card"]["rendered"] - last["settled"]) > 2:
    sys.exit("nested dropdown did not restore its full height")
if sys.argv[2] == "on":
    heights = [f["card"]["rendered"] for f in restored]
    total = last["settled"] - filtered[-1]["card"]["rendered"]
    if any(b < a - 2 or b - a > total * 0.55
           for a, b in zip(heights, heights[1:])):
        sys.exit("nested dropdown jumped during restore")
    # The first growing frame is where the steep open curve showed up: the
    # card used to land a third of the way in a single tick, then ease the
    # rest. The swap may lift the card to the row's rest height, but the
    # unfold itself has to start from rest.
    if len(heights) > 1 and heights[1] - heights[0] > total * 0.2:
        sys.exit("nested dropdown jumped on its first restoring frame")
    # The first restored frame still carries the filter card's height while
    # the taller page row appears underneath it. From the first unfold frame
    # on, the card has to cover the row's live height: a shorter viewport
    # would clip the dropdown while its content is on screen.
    for frame in restored[1:]:
        row = group(frame)
        if frame["card"]["viewFade"] > 0.05 and row \
                and frame["card"]["rendered"] < row["h"] - 2:
            sys.exit("nested dropdown was clipped while visible")
PY

  # A search hit can carry no sub of its own while the live page row it
  # points at does. The card's model-side fit and the delegate must resolve
  # that sub the same way, or the last result is cut through by a row gap.
  p close >/dev/null
  p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc" >/dev/null
  sleep 0.6
  p debugDeep on >/dev/null
  p deepPhase search-fit >/dev/null
  p debugType night >/dev/null
  sleep 0.5
  p debugDeep off >/dev/null
  local search_trace="${part}-search-fit.json"
  drain_trace "$search_trace" || return 1
  python3 - "$search_trace" <<'PY' || return 1
import json, sys

frames = [f for f in json.load(open(sys.argv[1]))
          if f["phase"] == "search-fit" and f["base"]["count"] > 1]
if not frames:
    sys.exit("search projection did not install")
# The head of the phase still holds the outgoing page, whose taller content
# is legitimately scrollable. Only the settled tail can answer whether the
# fit left the last result cut through.
for f in frames[-3:]:
    card, scroll, base = f["card"], f["scroll"], f["base"]
    if card["rendered"] < scroll["contentH"] - 2 or base["blank"] < -2:
        sys.exit(f"search card clipped {base['blank']}px of its last row")
PY

  # A short dropdown on a long page must not reach its own settled bottom and
  # then jump to the page's resting height when the slot settles. The fit
  # tween owns the whole resize in that case.
  p close >/dev/null
  p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#bar" >/dev/null
  sleep 0.6
  p debugSetCurrentIdx 2 >/dev/null
  p debugActivatePanel >/dev/null
  sleep 0.5
  p debugDeep on >/dev/null
  p debugBeginScoped >/dev/null
  p debugType night >/dev/null
  sleep 0.4
  p deepPhase short-dropdown >/dev/null
  p debugType "" >/dev/null
  sleep 0.6
  p debugDeep off >/dev/null
  local short_trace="${part}-short-dropdown.json"
  drain_trace "$short_trace" || return 1
  python3 - "$short_trace" "$motion" <<'PY' || return 1
import json, sys

frames = [f for f in json.load(open(sys.argv[1]))
          if f["phase"] == "short-dropdown" and f["base"]["count"] == 6]
if not frames:
    sys.exit("short dropdown restore did not install")
last = frames[-1]
if abs(last["card"]["rendered"] - last["base"]["tenRowH"]) > 2:
    sys.exit("short dropdown did not land on the page's resting height")
if sys.argv[2] == "on":
    heights = [f["card"]["rendered"] for f in frames]
    total = heights[-1] - heights[0]
    if total > 0 and any(b - a > total * 0.45
                         for a, b in zip(heights, heights[1:])):
        sys.exit("short dropdown jumped mid-resize")
    # The saved scroll stays put while the viewport grows around it. A
    # pursuit that scrolls down and is snapped back on settle reads as a
    # second, late animation instead of one parallel resize.
    offsets = [f["scroll"]["contentY"] for f in frames]
    if any(abs(b - a) > 2 for a, b in zip(offsets, offsets[1:])):
        sys.exit("short dropdown scroll jumped during the resize")
PY

  # A submenu picked inside the opening window is a real resize, not part of
  # the spawn. The show gate still snaps the summon's own fit; the navigation
  # that follows must tween from the height on screen to the new page.
  p close >/dev/null
  p debugDeep on >/dev/null
  p deepPhase instant-open >/dev/null
  p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#main" >/dev/null
  p debugSetCurrentIdx 0 >/dev/null
  p deepPhase instant-nav >/dev/null
  p debugActivatePanel >/dev/null
  sleep 0.6
  p debugDeep off >/dev/null
  local nav_trace="${part}-instant-nav.json"
  drain_trace "$nav_trace" || return 1
  python3 - "$nav_trace" "$motion" <<'PY' || return 1
import json, sys

frames = json.load(open(sys.argv[1]))
opening = [f for f in frames
           if f["phase"] == "instant-open" and f["base"]["page"] == "main"]
nav = [f for f in frames
       if f["phase"] == "instant-nav" and f["base"]["page"] == "settings"]
if not opening or not nav:
    sys.exit("instant navigation did not reach the submenu")
if sys.argv[2] == "on":
    heights = [f["card"]["rendered"] for f in nav]
    if len(heights) < 4 or len(set(round(h) for h in heights)) < 3:
        sys.exit("instant navigation switched height in one frame")
PY

  # Seeded, not fixed: the walk is reproducible but still crosses entries,
  # nested groups, editors, option grids, search and filter in odd orders.
  RANDOM=90210
  open_fixture
  p debugDeep on >/dev/null 2>&1
  for ((i = 0; i < iterations; i++)); do
    local pick=$((RANDOM % 19))
    case $pick in
      0) p deepPhase "move-down" >/dev/null 2>&1; p debugKey down >/dev/null 2>&1 ;;
      1) p deepPhase "move-up" >/dev/null 2>&1; p debugKey up >/dev/null 2>&1 ;;
      2) p deepPhase "move-tab" >/dev/null 2>&1; p debugKey tab >/dev/null 2>&1 ;;
      3) p deepPhase "move-backtab" >/dev/null 2>&1; p debugKey backtab >/dev/null 2>&1 ;;
      4) p deepPhase "move-left" >/dev/null 2>&1; p debugKey left >/dev/null 2>&1 ;;
      5) p deepPhase "move-right" >/dev/null 2>&1; p debugKey right >/dev/null 2>&1 ;;
      6) p deepPhase "activate" >/dev/null 2>&1; p debugActivatePanel >/dev/null 2>&1 ;;
      7) p deepPhase "escape" >/dev/null 2>&1; p debugEscape >/dev/null 2>&1 ;;
      8) p deepPhase "child-next" >/dev/null 2>&1; p debugChildMove 1 >/dev/null 2>&1 ;;
      9) p deepPhase "child-prev" >/dev/null 2>&1; p debugChildMove -1 >/dev/null 2>&1 ;;
      10) p deepPhase "option-next" >/dev/null 2>&1; p debugMoveOption 1 >/dev/null 2>&1 ;;
      11) p deepPhase "option-prev" >/dev/null 2>&1; p debugMoveOption -1 >/dev/null 2>&1 ;;
      12) p deepPhase "search" >/dev/null 2>&1
          p debugType "${WORDS[$((RANDOM % ${#WORDS[@]}))]}" >/dev/null 2>&1 ;;
      13) p deepPhase "filter" >/dev/null 2>&1
          p debugBeginScoped >/dev/null 2>&1
          p debugType "${WORDS[$((RANDOM % ${#WORDS[@]}))]}" >/dev/null 2>&1 ;;
      14) p deepPhase "info" >/dev/null 2>&1; p debugInfo >/dev/null 2>&1 ;;
      15) p deepPhase "editor-text" >/dev/null 2>&1
          p debugText "${CHARS[$((RANDOM % ${#CHARS[@]}))]}" >/dev/null 2>&1 ;;
      16) p deepPhase "jump" >/dev/null 2>&1
          p debugSetCurrentIdx "$((RANDOM % 18))" >/dev/null 2>&1 ;;
      17) p deepPhase "step-value" >/dev/null 2>&1
          if ((RANDOM % 2)); then p debugKey plus >/dev/null 2>&1
          else p debugKey minus >/dev/null 2>&1; fi ;;
      18) p deepPhase "big-move" >/dev/null 2>&1
          case $((RANDOM % 4)) in
            0) p debugKey home >/dev/null 2>&1 ;;
            1) p debugKey endKey >/dev/null 2>&1 ;;
            2) p debugKey pageUp >/dev/null 2>&1 ;;
            3) p debugKey pageDown >/dev/null 2>&1 ;;
          esac ;;
    esac
    sleep "$sleep_s"
  done

  p debugDeep off >/dev/null 2>&1
  drain_trace "${part}-random.json" || return 1
  python3 - "$trace" "${parts[@]}" "${part}-random.json" <<'PY'
import json, sys
out = sys.argv[1]
merged = []
for src in sys.argv[2:]:
    with open(src) as f:
        merged.extend(json.load(f))
with open(out, "w") as f:
    json.dump(merged, f, separators=(",", ":"))
PY
  local frames
  frames=$(python3 -c "import json,sys; print(len(json.load(open('$trace'))))" 2>/dev/null || echo 0)
  if ((frames > 0)); then
    t_ok "$mode: the frame sampler recorded a trace" "frames=$frames"
  else
    t_no "$mode: the frame sampler recorded a trace" "frames=$frames"
  fi
  t_status "$mode: every frame obeys the reactive invariants" 0 \
    python3 "$ANALYZER" "$trace" "$mode"
}

t_section "pass 1: animations on"
walk animations 0.12 28 || t_no "animations: the capture completed"

t_section "pass 2: animations collapsed"
walk noanim 0.04 28 || t_no "noanim: the capture completed"

# Regression: clearing a global search must not paint the result row under
# the bar while the page's rows resize back. The old path kept the hit by
# identity for one install, then moved to the saved seat on the next frame -
# a visible Reload flash. Start on a row that is not the page head, so the
# assertion also proves the saved seat, not just "row zero".
t_section "search clear keeps the pre-search seat with no result flash"
p close >/dev/null 2>&1 || true
sleep 0.3
p restoreAnims >/dev/null 2>&1 || true
p openFile "$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#utilities" >/dev/null
sleep 0.7
p debugSetCurrentIdx 4 >/dev/null
sleep 0.25
p debugDeep on >/dev/null
sleep 0.2
p debugType "Reload" >/dev/null
sleep 0.65
p debugKey escape >/dev/null
sleep 0.65
SEARCH_TRACE="${TMPDIR:-/tmp}/vb-menu-search-clear.jsonl"
: > "$SEARCH_TRACE"
for off in 0 8 16 24 32 40 48 56 64 72 80 88; do
  p probeDeep "$off" 8 >> "$SEARCH_TRACE" 2>/dev/null || true
  printf '\n' >> "$SEARCH_TRACE"
done
p debugDeep off >/dev/null 2>&1 || true
search_result=$(python3 - "$SEARCH_TRACE" <<'PY'
import json, sys
frames = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        frames.extend(json.loads(line))
cleared = [f for f in frames
           if f["base"]["query"] == "" and not f["base"]["searching"]]
bad = [f for f in cleared if f["base"]["rowLabel"] == "Reload Vibranium"]
# The target is 4. -1 is the deliberate empty swap frame while the page
# rows are being adopted; any other index is the first-entry frame the bug
# painted before the saved row won.
wrong = [f for f in cleared if f["base"]["index"] not in (4, -1)]
last = frames[-1]["base"] if frames else {}
print(f"{len(bad)}|{len(wrong)}|{last.get('index', -1)}|{last.get('rowLabel', '')}")
PY
)
t_eq "no cleared-search frame paints the Reload hit" "0" "${search_result%%|*}"
rest=${search_result#*|}
t_eq "no cleared-search frame seats another row" "0" "${rest%%|*}"
rest=${rest#*|}
t_eq "the saved row is the cursor after the resize" "4" "${rest%%|*}"
t_eq "the saved row is Reading mode" "Reading mode" "${rest#*|}"
p close >/dev/null 2>&1 || true
