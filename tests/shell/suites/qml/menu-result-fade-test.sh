#!/bin/bash
# Suite: menu-result-fade - one handoff value drives the result presentation.
#
# A result selection used to run three animations on three properties with
# the same duration token. They agreed while nothing stalled, but nothing in
# the system knew about the others. The panel now writes one handoff value;
# page opacity, query text, the field's focus border and its ghost are all
# functions of that value. This suite drives a real selection on the live
# shell and samples the probe over CONSECUTIVE frames, so an end state after
# a sleep could not satisfy it.
#
# The suite is skipped when the shell service is not up: it must never start
# a standalone qs process for a test, and it must never be counted as a pass
# when it did not exercise the live shell.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "menu-result-fade" "one handoff progress behind four result presentations"

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

FIXTURE="$VIBRANIUM_DIR/shell/common/settings/catalog.jsonc#main"
if [[ ! -f ${FIXTURE%%#*} ]]; then
  t_block "the settings catalog fixture is missing: $FIXTURE"
fi

p() { qs -p "$VIBRANIUM_DIR/shell" ipc call menu "$@"; }

probe_field() {
  p probe | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null
}

# One frame: handoff pageOpacity textOpacity fieldHandoff ghostOpacity page.
probe_frame() {
  p probe | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['handoff'], d['pageOpacity'], d['textOpacity'], d['fieldHandoff'], d['ghostOpacity'], d['page'])" 2>/dev/null
}

# The deep frame sampler lives in the resident panel: a 16 ms timer records
# each animation frame locally, so the suite reads a finished array after the
# animation instead of missing frames to process-per-round-trip polling. The
# six values below are the exact same six `menu probe` fields the suite has
# always asserted on; only the measurement moved into the shell.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-menu-result-fade.XXXXXX")"

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

deep_frames() {
  python3 - "$@" <<'PY'
import json, sys
for path in sys.argv[1:]:
    for line in open(path):
        for f in json.loads(line):
            b = f["base"]
            print(b["handoff"], b["pageOpacity"], b["textOpacity"],
                  b["fieldHandoff"], b["ghostOpacity"], b["page"])
PY
}

cleanup() {
  p debugTrace off >/dev/null 2>&1
  p debugDeep off >/dev/null 2>&1
  p close >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

t_section "result handoff is one value with four derivations"

p close >/dev/null 2>&1
p openFile "$FIXTURE" >/dev/null 2>&1
sleep 0.7
p debugType "time format" >/dev/null 2>&1
sleep 0.6
t_eq "the query is live before the handoff" "time format" \
  "$(probe_field 'd["query"]')"
t_eq "the driver rests at zero" "0" "$(probe_field 'd["handoff"]')"
t_eq "the results are still on screen" "main" "$(probe_field 'd["page"]')"

# The verb under test: Enter on a search hit. Arm the resident frame sampler,
# fire the handoff, then read the whole consecutive frame array in one reply.
# No external polling and no animation change: the assertions below are
# unchanged and still compare all four presentations to the one source value.
p debugDeep on >/dev/null 2>&1
p debugActivatePanel >/dev/null 2>&1
sleep 0.5
p debugDeep off >/dev/null 2>&1
collect_deep "$WORK/deep.jsonl"
frames="$(deep_frames "$WORK/deep.jsonl")"

# frame_metrics <frames> -> mid minPos maxH badPage badText badField
#   earlyGhost lateGhost lateMono wrongBefore wrongAfter finalPage
#   finalHandoff finalPageOpacity
frame_metrics() {
  printf '%s\n' "$1" | python3 -c '
import sys
rows = []
for line in sys.stdin:
    f = line.split()
    if len(f) != 6:
        continue
    try:
        rows.append((float(f[0]), float(f[1]), float(f[2]), float(f[3]),
                     float(f[4]), f[5]))
    except ValueError:
        continue

def page_curve(h):
    if h <= 0.5:
        return 1 - min(2 * h, 1)
    k = (h - 0.5) * 2
    return 0.3 + 0.7 * (1 - (1 - k) ** 3)

def text_curve(h):
    return (1 - min(2 * h, 1)) ** 3

mid = [r for r in rows if 0 < r[0] < 1]
pos = [r[0] for r in rows if r[0] > 0]
start = next((i for i, r in enumerate(rows) if r[0] >= 0.5), len(rows))
late = [r[4] for r in rows[start:]]
bad_page = sum(1 for r in mid if abs(r[1] - page_curve(r[0])) > 0.025)
bad_text = sum(1 for r in mid if abs(r[2] - text_curve(r[0])) > 0.025)
bad_field = sum(1 for r in rows if r[0] > 0 and abs(r[3] - r[0]) > 0.002)
early_ghost = sum(1 for r in rows if 0 < r[0] < 0.5 and r[4] > 0.01)
late_mono = sum(1 for i in range(1, len(late))
                if late[i] + 0.02 < late[i - 1])
wrong_before = sum(1 for r in rows
                   if 0 < r[0] < 0.5 and r[5] != "main")
wrong_after = sum(1 for r in rows if r[0] > 0.5 and r[5] != "general")
last = rows[-1] if rows else (0, 0, 0, 0, 0, "")
print(len(mid),
      round(min(pos), 3) if pos else -1,
      round(max(pos), 3) if pos else -1,
      bad_page, bad_text, bad_field, early_ghost,
      round(late[-1], 3) if late else -1,
      late_mono, wrong_before, wrong_after, last[5],
      last[0], last[1])
'
}

read -r m_mid m_min m_max m_badPage m_badText m_badField m_earlyGhost \
  m_lateGhost m_lateMono m_wrongBefore m_wrongAfter m_finalPage \
  m_finalHandoff m_finalPageOpacity <<<"$(frame_metrics "$frames")"

t_eq "handoff is sampled across consecutive frames" "True" \
  "$(python3 -c "print($m_mid >= 4)")"
t_eq "the source value covers both phases" "True" \
  "$(python3 -c "print($m_min <= 0.4 and $m_max >= 0.8 and $m_max - $m_min >= 0.6)")"
t_eq "page opacity equals its function of handoff in every frame" "0" \
  "$m_badPage"
t_eq "query text equals the eased complement in every frame" "0" \
  "$m_badText"
t_eq "the field sees the same handoff value in every frame" "0" \
  "$m_badField"
t_eq "the ghost is held through phase one" "0" "$m_earlyGhost"
t_eq "the ghost rides in with the reveal" "True" \
  "$(python3 -c "print($m_lateGhost >= 0.8)")"
t_eq "the ghost never dims once revealed" "0" "$m_lateMono"
t_eq "the page switch waits for the phase-one edge" "0" "$m_wrongBefore"
t_eq "the page switch has committed by phase two" "0" "$m_wrongAfter"
t_eq "the hit's page is revealed" "general" "$m_finalPage"
t_eq "the driver returns to its idle origin" "True" \
  "$(python3 -c "print(abs($m_finalHandoff) < 0.001)")"
t_eq "the revealed page is fully opaque" "True" \
  "$(python3 -c "print(abs($m_finalPageOpacity - 1) < 0.001)")"

t_summary
