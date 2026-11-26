#!/bin/bash
# Suite: tools picker - the standalone region pick reports a rectangle, waits
# for a settled answer, and reports nothing but RC 1 when it is discarded.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "tools-picker" "a standalone region pick via the public CLI"

CLIENT="$VIBRANIUM_DIR/bin/vb-shell"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-tools-picker.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export PATH="$TESTS_SHELL_DIR/suites/cli/fixtures:$PATH"
export VIBRANIUM="$VIBRANIUM_DIR"
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/vb-tools-picker-pycache"

pick() {
  : >"$WORK/counter"
  FAKE_QS_MODE=tools-picker FAKE_QS_COUNTER="$WORK/counter" \
    python3 -B "$CLIENT" "$@" >"$WORK/out" 2>"$WORK/err"
  STATUS=$?
}

t_section "an accepted pick reports its rectangle"
pick tools picker pick
t_eq "the pick exits 0" "0" "$STATUS"
t_eq "the rectangle is rendered as a typed record" 'x: 12
y: 34
w: 640
h: 480' "$(cat "$WORK/out")"
t_empty "stderr stays clean" "$(cat "$WORK/err")"
t_eq "the pending answer was polled once" "2" "$(cat "$WORK/counter")"

t_section "silent is forwarded as one literal word"
: >"$WORK/counter"
: >"$WORK/log"
FAKE_QS_LOG="$WORK/log" FAKE_QS_MODE=tools-picker FAKE_QS_COUNTER="$WORK/counter" \
  python3 -B "$CLIENT" tools picker pick silent >"$WORK/out" 2>"$WORK/err"
  STATUS=$?
t_eq "the silent pick exits 0" "0" "$STATUS"
t_eq "the modifier reaches the transport verbatim" "silent" \
  "$(python3 - "$WORK/log" <<'PY'
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
env = json.loads(lines[0]['argv'][6][3:])
print(env['argv'][-1])
PY
)"

t_section "a discarded selection is silent except for RC 1"
FAKE_QS_MODE=tools-picker-cancel \
  python3 -B "$CLIENT" tools picker pick >"$WORK/out" 2>"$WORK/err"
  STATUS=$?
t_eq "Escape exits 1" "1" "$STATUS"
t_empty "no rectangle is printed" "$(cat "$WORK/out")"

t_section "stop is a silent action"
FAKE_QS_MODE=tools-stop python3 -B "$CLIENT" tools picker stop >"$WORK/out" 2>"$WORK/err"
STATUS=$?
t_eq "stop exits 0" "0" "$STATUS"
t_empty "stop prints no stdout" "$(cat "$WORK/out")"
t_empty "stop prints no stderr" "$(cat "$WORK/err")"

