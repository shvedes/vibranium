#!/bin/bash
# Suite: menu-dropdown-scrolloff - long group dropdowns scroll behind the card.
#
# A group with more children than the card can show used to publish its whole
# column as the row height. The card refused to grow past the screen ceiling,
# so the lower children were clipped while the cursor kept walking them, and
# closing the entry bounced the window height. The group now caps its viewport
# against the ceiling and scrolls its column with the cursor held dead centre.
#
# This suite drives the live shell over IPC and samples consecutive probe
# frames, so an end state reached by a wrong interpolation cannot pass.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "menu-dropdown-scrolloff" "long group dropdowns cap and scroll inside the card"

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

p() { qs -p "$VIBRANIUM_DIR/shell" ipc call menu "$@" 2>/dev/null; }
probe_field() {
  p probe | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null
}
# One frame: ceiling, group ceiling, natural, viewport, capped, scrollY,
# column Y, bar Y, child index, card height, contentY.
probe_frame() {
  p probe | python3 -c '
import json,sys
d=json.load(sys.stdin); g=d["geom"]
print(d["slotCeilingH"], d["grpCeilingH"], d["grpNaturalH"], d["grpViewportH"],
      d["grpCapped"], d["grpScrollY"], d["grpColY"], d["grpBarY"],
      d["childIndex"], g["cardH"], d["contentY"])
' 2>/dev/null
}
# numpy-free comparisons: emit True/False for a python expression over two values.
cmp2() { python3 -c "import sys; a,b=map(float,sys.argv[1:3]); print($1)" "$2" "$3"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-menu-scrolloff.XXXXXX")"
LONG="$WORK/long.json"
SHORT="$WORK/short.json"
DEMO="$WORK/demo.json"
python3 - "$LONG" <<'PY'
import json, sys
children = [
  {"type": "action", "label": f"Option {i:02d}", "id": f"opt{i:02d}",
   "command": f"echo opt{i}"} for i in range(1, 41)
]
bundle = {"menus": [{"id": "main", "label": "Trace", "items": [
  {"type": "group", "id": "longGroup", "label": "Long group",
   "sub": "40 children", "children": children},
  {"type": "action", "id": "tail", "label": "Tail row", "command": "echo tail"}
]}]}
open(sys.argv[1], "w").write(json.dumps(bundle))
PY
python3 - "$SHORT" <<'PY'
import json, sys
bundle = {"menus": [{"id": "main", "label": "Short", "items": [
  {"type": "group", "id": "shortGroup", "label": "Short group", "children": [
    {"type": "action", "label": f"Opt {i}", "id": f"o{i}", "command": "echo x"}
    for i in range(1, 4)
  ]}
]}]}
open(sys.argv[1], "w").write(json.dumps(bundle))
PY
# Mirrors /tmp/opencode/dropdown/try-long.sh: a long normal page list, a
# long group, and a nested long group, all in one page.
python3 - "$DEMO" <<'PY'
import json, sys

def act(i, sub=False):
    row = {"type": "action", "label": f"Option {i:02d}",
           "id": f"opt{i:02d}", "command": f"echo opt{i}"}
    if sub:
        row["sub"] = f"detail line {i:02d} (a taller row)"
    return row

inner = {"type": "group", "id": "inner", "label": "Inner group",
         "sub": "30 tall children",
         "children": [act(i, True) for i in range(31, 61)]}
deep = {"type": "group", "id": "deep", "label": "Deep group",
        "sub": "12 children, last one nested",
        "children": [act(i) for i in range(1, 12)] + [inner]}
long_group = {"type": "group", "id": "longGroup", "label": "Long group",
              "sub": "30 tall children",
              "children": [act(i, True) for i in range(1, 31)]}
plain = [act(i) for i in range(31, 55)]
bundle = {"menus": [{"id": "main", "label": "Scrolloff demo",
                     "items": [deep, long_group] + plain}]}
open(sys.argv[1], "w").write(json.dumps(bundle))
PY

cleanup() {
  p debugTrace off >/dev/null 2>&1
  p close >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

t_section "a group taller than the card caps its viewport"

p close >/dev/null 2>&1
sleep 0.3
p open "$(<"$LONG")" >/dev/null 2>&1
sleep 0.5
p debugSetCurrentIdx 0 >/dev/null
base_card="$(probe_field 'd["geom"]["cardH"]')"

p debugActivatePanel >/dev/null 2>&1
sleep 0.5
read -r ceiling grp_ceil natural viewport capped scroll col_y bar_y ci card cy \
  <<<"$(probe_frame)"
t_true "the card published a slot ceiling" test "$ceiling" -gt 0
t_eq "the group is capped against it" "True" "$capped"
t_true "the group's natural height exceeds the cap" test "$natural" -gt "$grp_ceil"
t_eq "the viewport is the cap" "True" \
  "$(cmp2 'abs(a-b)<0.6' "$viewport" "$grp_ceil")"
t_eq "the row never claims more than the ceiling" "True" \
  "$(cmp2 'a<=b' "$(probe_field 'd["rowH"]')" "$ceiling")"

t_section "the cursor scrolls the column without resizing the card"

: >"$WORK/frames.txt"
for _ in $(seq 1 34); do
  p debugAutoMove 1 >/dev/null 2>&1
  sleep 0.05
  probe_frame >>"$WORK/frames.txt"
done

python3 - "$WORK/frames.txt" "$viewport" >"$WORK/metrics.txt" <<'PY'
import sys
rows = []
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) != 11:
        continue
    ce, gce, nat, view, cap, scroll, col, bar, ci, card, cy = parts
    rows.append(dict(scroll=float(scroll), col=float(col), bar=float(bar),
                     view=float(view), card=float(card)))
print("frames", len(rows))
print("advances", sum(1 for a, b in zip(rows, rows[1:]) if b["scroll"] > a["scroll"] + 0.5))
print("col_tracks", all(abs(r["col"] + r["scroll"]) < 0.6 for r in rows))
print("bar_bound", all(r["bar"] <= r["view"] + 0.6 for r in rows))
print("card_steady", len({round(r["card"]) for r in rows}) == 1)
print("last_scroll", round(rows[-1]["scroll"], 1))
PY
while read -r key value; do
  case "$key" in
    frames) t_true "the trace is non-empty" test "$value" -ge 30 ;;
    advances) t_true "the scroll advanced monotonically" test "$value" -ge 8 ;;
    col_tracks) t_eq "the column translation is exactly -scrollY" "True" "$value" ;;
    bar_bound) t_eq "the cursor bar stays inside the viewport" "True" "$value" ;;
    card_steady) t_eq "the card does not resize while scrolling" "True" "$value" ;;
    last_scroll) t_true "the last seat is non-trivial" \
      test "$(cmp2 'a>100' "$value" 0)" == True ;;
  esac
done <"$WORK/metrics.txt"

t_section "the cursor centres and the clipped edges hint at more content"

p close >/dev/null 2>&1
sleep 0.3
p open "$(<"$LONG")" >/dev/null 2>&1
sleep 0.5
p debugActivatePanel >/dev/null 2>&1
sleep 0.5
t_eq "the lower edge hints at content below" "True" \
  "$(probe_field 'd["grpFadeBottom"]')"
t_eq "the upper edge has nothing to hint at yet" "False" \
  "$(probe_field 'd["grpFadeTop"]')"
t_eq "the lower hint is fully faded in" "True" \
  "$(cmp2 'abs(a-1)<0.02' "$(probe_field 'd["grpFadeBottomOpacity"]')" 0)"
t_eq "the upper hint is fully faded out" "True" \
  "$(cmp2 'abs(a)<0.02' "$(probe_field 'd["grpFadeTopOpacity"]')" 0)"

for _ in $(seq 1 18); do
  p debugAutoMove 1 >/dev/null 2>&1
  sleep 0.04
done
sleep 0.35
bar="$(probe_field 'd["grpBarY"]')"
bar_h="$(probe_field 'd["grpBarH"]')"
view="$(probe_field 'd["grpViewportH"]')"
t_eq "both edges hint mid-list" "True True" \
  "$(probe_field 'd["grpFadeTop"]') $(probe_field 'd["grpFadeBottom"]')"
t_eq "both hints have faded in mid-list" "True" \
  "$(python3 -c 'import sys; a,b=map(float,sys.argv[1:3]); print(abs(a-1)<0.02 and abs(b-1)<0.02)' \
    "$(probe_field 'd["grpFadeTopOpacity"]')" \
    "$(probe_field 'd["grpFadeBottomOpacity"]')")"
t_eq "the cursor settles dead centre, not against an edge" "True" \
  "$(python3 -c 'import sys; a,b,c=map(float,sys.argv[1:4]); print(abs(a+b/2-c/2)<2)' \
    "$bar" "$bar_h" "$view")"

# Stop on the last child: the group cursor wraps, so stepping past it would
# start a new lap and put content back below the viewport.
for _ in $(seq 1 21); do
  p debugAutoMove 1 >/dev/null 2>&1
  sleep 0.03
done
sleep 0.35
t_eq "the lower hint retires at the end of the list" "False" \
  "$(probe_field 'd["grpFadeBottom"]')"
t_eq "the upper hint stays at the end of the list" "True" \
  "$(probe_field 'd["grpFadeTop"]')"

t_section "a short group keeps its natural height"

p close >/dev/null 2>&1
sleep 0.3
p open "$(<"$SHORT")" >/dev/null 2>&1
sleep 0.4
p debugActivatePanel >/dev/null 2>&1
sleep 0.4
t_eq "the short group is not capped" "False" "$(probe_field 'd["grpCapped"]')"
t_eq "the short group does not scroll" "True" \
  "$(cmp2 'abs(a)<0.6' "$(probe_field 'd["grpScrollY"]')" 0)"

t_section "a long normal page list keeps its cursor inside the viewport"

p close >/dev/null 2>&1
sleep 0.3
p open "$(<"$DEMO")" >/dev/null 2>&1
sleep 0.6
t_true "the page has many rows" test "$(probe_field 'd["count"]')" -ge 20
list_h="$(probe_field 'd["geom"]["listH"]')"
: >"$WORK/page.txt"
for _ in $(seq 1 14); do
  p debugAutoMove 1 >/dev/null 2>&1
  sleep 0.05
  p probe | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["contentY"], d["hlY"], d["index"])
' >>"$WORK/page.txt"
done
python3 - "$WORK/page.txt" "$list_h" >"$WORK/page-metrics.txt" <<'PY'
import sys
rows = []
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) == 3:
        rows.append(tuple(map(float, parts)))
view = float(sys.argv[2])
print("advanced", rows[-1][0] > 0)
print("bar_visible", all(-0.6 <= b - a <= view + 0.6 for a, b, _ in rows))
print("index_moved", rows[-1][2] > rows[0][2])
PY
while read -r key value; do
  case "$key" in
    advanced) t_eq "the page scrolled" "True" "$value" ;;
    bar_visible) t_eq "the highlight stays in the viewport" "True" "$value" ;;
    index_moved) t_eq "the cursor walked the long list" "True" "$value" ;;
  esac
done <"$WORK/page-metrics.txt"

t_section "a nested group caps and scrolls against its own ceiling"

p close >/dev/null 2>&1
sleep 0.3
p open "$(<"$DEMO")" >/dev/null 2>&1
sleep 0.6
p debugSetCurrentIdx 0 >/dev/null 2>&1
sleep 0.1
p debugActivatePanel >/dev/null 2>&1
sleep 0.5
for _ in $(seq 1 11); do
  p debugAutoMove 1 >/dev/null 2>&1
  sleep 0.04
done
p debugActivatePanel >/dev/null 2>&1
sleep 0.8
t_eq "the nested group is capped" "True" \
  "$(probe_field 'd["innerGroupCapped"]')"
inner_nat="$(probe_field 'd["innerGroupNaturalH"]')"
inner_view="$(probe_field 'd["innerGroupViewportH"]')"
t_true "its column is taller than its viewport" \
  test "$inner_nat" -gt "$inner_view"

: >"$WORK/inner.txt"
for _ in $(seq 1 15); do
  p debugAutoMove 1 >/dev/null 2>&1
  sleep 0.04
  p probe | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["innerGroupScrollY"], d["innerGroupChildIndex"],
      d["innerFocusBarY"], d["innerFocusBarH"])
' >>"$WORK/inner.txt"
done
python3 - "$WORK/inner.txt" "$inner_view" >"$WORK/inner-metrics.txt" <<'PY'
import sys
rows = []
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) == 4:
        rows.append(tuple(map(float, parts)))
view = float(sys.argv[2])
print("advances", sum(1 for a, b in zip(rows, rows[1:]) if b[0] > a[0] + 0.5))
# Before the cursor reaches the middle the column correctly does not move, so
# pin the centre only on frames where a scroll seat actually happened.
scrolling = [r for r in rows if r[0] > 0.5]
print("centred", bool(scrolling)
      and all(abs(r[2] + r[3] / 2 - view / 2) < 3 for r in scrolling))
print("idx_moved", rows[-1][1] > rows[0][1])
PY
while read -r key value; do
  case "$key" in
    advances) t_true "the nested column scrolled" test "$value" -ge 5 ;;
    centred) t_eq "the nested cursor stays centred" "True" "$value" ;;
    idx_moved) t_eq "the nested cursor walked its children" "True" "$value" ;;
  esac
done <"$WORK/inner-metrics.txt"

t_section "closing returns to the base height without a bounce"

p close >/dev/null 2>&1
sleep 0.3
p open "$(<"$LONG")" >/dev/null 2>&1
sleep 0.5
p debugActivatePanel >/dev/null 2>&1
sleep 0.5
open_card="$(probe_field 'd["geom"]["cardH"]')"
p debugEscape >/dev/null 2>&1
: >"$WORK/close.txt"
for _ in $(seq 1 8); do
  sleep 0.05
  probe_field 'd["geom"]["cardH"]' >>"$WORK/close.txt"
done
python3 - "$WORK/close.txt" "$open_card" "$base_card" >"$WORK/close-metrics.txt" <<'PY'
import sys
vals = [float(x) for x in open(sys.argv[1]) if x.strip()]
open_card, base = float(sys.argv[2]), float(sys.argv[3])
print("monotone", all(b <= a + 0.6 for a, b in zip(vals, vals[1:])))
print("no_overshoot", all(v <= open_card + 0.6 for v in vals))
print("landed", abs(vals[-1] - base) < 0.6)
PY
while read -r key value; do
  case "$key" in
    monotone) t_eq "the card shrinks monotonically" "True" "$value" ;;
    no_overshoot) t_eq "the card never grows past the open height" "True" "$value" ;;
    landed) t_eq "the card lands at the base height" "True" "$value" ;;
  esac
done <"$WORK/close-metrics.txt"

t_summary
