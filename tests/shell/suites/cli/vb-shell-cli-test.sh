#!/bin/bash
# Suite: vb-shell CLI - exact argv, both streams, status codes and paging.
#
# The fake `qs` fixture records every forwarded word and answers with canned
# v1 frames. Nothing here starts a desktop shell or reads a user's config.
# The SVG-free assertions are about bytes: whitespace, empty strings, Unicode,
# leading hyphens, stderr, exit status and single-LF output.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "vb-shell-cli" "argv preservation, wire contract, rendering and paging"

CLIENT="$VIBRANIUM_DIR/bin/vb-shell"
FIXTURE="$TESTS_SHELL_DIR/suites/cli/fixtures"
PYCACHE="${TMPDIR:-/tmp}/opencode/vb-shell-cli-pycache"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-cli.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

t_file "the Python client exists" "$CLIENT"
t_true "the client compiles" env PYTHONPYCACHEPREFIX="$PYCACHE" python3 -B -m py_compile "$CLIENT"

t_section "stdlib-only client"
t_eq "no wcwidth reference of any kind" "0" "$(grep -ci 'wcwidth\|wcswidth' "$CLIENT")"
t_eq "every imported module is in the stdlib" "" "$(python3 - "$CLIENT" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding='utf-8').read())
mods = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        mods.update(a.name.split('.')[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module:
        mods.add(node.module.split('.')[0])
print(','.join(sorted(m for m in mods if m not in sys.stdlib_module_names)))
PY
)"

export PATH="$FIXTURE:$PATH"
export VIBRANIUM="$VIBRANIUM_DIR"
export FAKE_QS_LOG="$WORK/qs.log"
export PYTHONPYCACHEPREFIX="$PYCACHE"
: >"$FAKE_QS_LOG"

cli() {
  local out="$1" err="$2" mode="${3:-ok}"
  shift 3
  FAKE_QS_MODE="$mode" python3 -B "$CLIENT" "$@" >"$out" 2>"$err"
  return $?
}

# The last logged call's request envelope, decoded back to its request object.
last_request() {
  python3 - "$FAKE_QS_LOG" <<'PY'
import json, sys
line = open(sys.argv[1], encoding='utf-8').read().splitlines()[-1]
argv = json.loads(line)['argv']
print(json.dumps(json.loads(argv[-1][len("v1:"):]), ensure_ascii=False, sort_keys=True))
PY
}

last_badenv() {
  python3 - "$FAKE_QS_LOG" <<'PY'
import json, sys
line = open(sys.argv[1], encoding='utf-8').read().splitlines()[-1]
print(json.dumps(json.loads(line)['badenv']))
PY
}

first_request() {
  python3 - "$FAKE_QS_LOG" <<'PY'
import json, sys
line = open(sys.argv[1], encoding='utf-8').read().splitlines()[0]
argv = json.loads(line)['argv']
print(json.dumps(json.loads(argv[-1][len("v1:"):]), ensure_ascii=False, sort_keys=True))
PY
}

assert_forwarded() {
  local label="$1" expected="$2"
  local actual
  actual="$(last_request)"
  t_eq "$label" "$expected" "$actual"
}

# ---------------------------------------------------------------------------
t_section "exact argv preservation"

cli "$WORK/out" "$WORK/err" ok state set 'a b' '{"x":"é 😀"}'
assert_forwarded "spaces, Unicode and JSON stay one atom" \
  '{"argv": ["state", "set", "a b", "{\"x\":\"é 😀\"}"], "kind": "call", "literalFrom": null, "v": 1}'
t_eq "the transport path is exactly qs -p VIBRANIUM/shell ipc call shell invoke" \
  '["-p", "'"$VIBRANIUM_DIR"'/shell", "ipc", "call", "shell", "invoke"]' \
  "$(python3 - "$FAKE_QS_LOG" <<'PY'
import json, sys
line = open(sys.argv[1], encoding='utf-8').read().splitlines()[-1]
print(json.dumps(json.loads(line)['argv'][:6]))
PY
)"

cli "$WORK/out" "$WORK/err" ok state set '' 'back\slash' 'line
break' '-leading' 'repeat repeat' '--still-data'
assert_forwarded "empty, backslash, LF, leading hyphen and repeated words" \
  '{"argv": ["state", "set", "", "back\\slash", "line\nbreak", "-leading", "repeat repeat", "--still-data"], "kind": "call", "literalFrom": null, "v": 1}'

cli "$WORK/out" "$WORK/err" ok state get slot -- -x --json
assert_forwarded "-- after a path marks the rest literal, and is not forwarded" \
  '{"argv": ["state", "get", "slot", "-x", "--json"], "kind": "call", "literalFrom": 3, "v": 1}'

cli "$WORK/out" "$WORK/err" ok state get --verbose
assert_forwarded "a global-looking word after a path is data" \
  '{"argv": ["state", "get", "--verbose"], "kind": "call", "literalFrom": null, "v": 1}'

t_eq "no inherited QS config variables reach the transport" "[]" "$(last_badenv)"

# The lock-state read moved from the removed lockscreen target onto session.
cli "$WORK/out" "$WORK/err" ok session isLocked
assert_forwarded "session isLocked forwards as one gateway call" \
  '{"argv": ["session", "isLocked"], "kind": "call", "literalFrom": null, "v": 1}'

# The top-level picker alias exists for keybinds; the bind spelling stays as-is.
: >"$FAKE_QS_LOG"
cli "$WORK/out" "$WORK/err" ok colorPicker pick
t_eq "colorPicker pick forwards as one gateway call" \
  '{"argv": ["colorPicker", "pick"], "kind": "call", "literalFrom": null, "v": 1}' \
  "$(first_request)"
cli "$WORK/out" "$WORK/err" ok colorPicker close
assert_forwarded "colorPicker close forwards as one gateway call" \
  '{"argv": ["colorPicker", "close"], "kind": "call", "literalFrom": null, "v": 1}'

# A none-format success is RC-only: neither stream carries the payload.
cli "$WORK/out" "$WORK/err" data-none emojiPicker copy '😀'
t_status "the silent route succeeds" 0 cli "$WORK/out" "$WORK/err" data-none emojiPicker copy '😀'
t_empty "a none-format success prints no stdout" "$(cat "$WORK/out")"
t_empty "a none-format success prints no stderr" "$(cat "$WORK/err")"

# ---------------------------------------------------------------------------
t_section "rearranged audio and launcher spellings forward verbatim"
for words in "audio volume up" "audio volume down step 10" "audio volume toggle" \
  "audio volume get" "audio volume set 80" "audio microphone up" "audio microphone down" \
  "audio microphone get" \
  "audio microphone toggle" "audio microphone set 60" "audio sink list" \
  "audio sink set n1.2" "audio source list" "audio source set n1.3" \
  "appLauncher history is-empty" "appLauncher history show" \
  "appLauncher history clear"; do
  read -ra parts <<<"$words"
  cli "$WORK/out" "$WORK/err" ok "${parts[@]}"
  t_contains "$words forwards one gateway call" '\"kind\":\"call\"' "$(cat "$WORK/qs.log" | tail -1)"
done
t_eq "rescan has no public catalog row" "0" \
  "$(grep -c 'appLauncher.rescan' "$SHELL_DIR/common/text/IpcCatalog.js" || true)"
cli "$WORK/out" "$WORK/err" ok audio volume up
assert_forwarded "audio volume up forwards its argv" \
  '{"argv": ["audio", "volume", "up"], "kind": "call", "literalFrom": null, "v": 1}'
cli "$WORK/out" "$WORK/err" ok appLauncher history show
assert_forwarded "appLauncher history show forwards its argv" \
  '{"argv": ["appLauncher", "history", "show"], "kind": "call", "literalFrom": null, "v": 1}'

cli "$WORK/out" "$WORK/err" audio-get-volume --json audio volume get
t_eq "volume get JSON is a typed level record" '{"muted": false, "percent": 80}' \
  "$(python3 - "$WORK/out" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))
PY
)"
cli "$WORK/out" "$WORK/err" audio-get-microphone --json audio microphone get
t_eq "microphone get JSON is a typed level record" '{"muted": true, "percent": 60}' \
  "$(python3 - "$WORK/out" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))
PY
)"

t_section "clipboard copy is a controller, not a data route"
: >"$FAKE_QS_LOG"
cli "$WORK/out" "$WORK/err" golden-clipboard-copy clipboard copy
t_status "bare copy succeeds" 0 cli "$WORK/out" "$WORK/err" golden-clipboard-copy clipboard copy
t_contains "bare copy prints the controller usage" "Usage: vb-shell clipboard copy" "$(cat "$WORK/out")"
t_contains "bare copy lists the verbs" "entry regular|pinned <INDEX>" "$(cat "$WORK/out")"
t_not_contains "no BUCKET placeholder in copy help" "<BUCKET>" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" golden-clipboard-copy clipboard copy help
t_status "copy help succeeds" 0 cli "$WORK/out" "$WORK/err" golden-clipboard-copy clipboard copy help
t_contains "copy help prints the controller usage" "Usage: vb-shell clipboard copy" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" ok clipboard copy text
t_status "a malformed stream form still fails locally" 2 cli "$WORK/out" "$WORK/err" ok clipboard copy text
t_contains "the local shape error is unchanged" "no such clipboard copy form" "$(cat "$WORK/err")"

t_section "clipboard copy entry is a gateway call, not a stream route"
cli "$WORK/out" "$WORK/err" ok clipboard copy entry regular 0
assert_forwarded "copy entry forwards one invoke envelope" \
  '{"argv": ["clipboard", "copy", "entry", "regular", "0"], "kind": "call", "literalFrom": null, "v": 1}'

t_section "the four stream formats still take the data route"
for form in "text hello" "uri https://example.org/a" "file ./notes.txt"; do
  read -ra parts <<<"$form"
  : >"$FAKE_QS_LOG"
  FAKE_QS_MODE=ok python3 -B "$CLIENT" clipboard copy "${parts[@]}" >"$WORK/out" 2>"$WORK/err" || true
  t_contains "copy ${parts[0]} confirms via clipboard ping" "ping" "$(cat "$FAKE_QS_LOG")"
  t_not_contains "copy ${parts[0]} sends no gateway invoke" '"kind":"call"' "$(cat "$FAKE_QS_LOG")"
done

t_section "bar status is a typed record"
cli "$WORK/out" "$WORK/err" bar-status-record bar status
t_not_contains "text output has no raw JSON braces" "{" "$(cat "$WORK/out")"
t_contains "text output shows ordered keys" "effectiveEnabled: true" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" bar-status-record --json bar status
t_eq "JSON mode emits the same data" "top" \
  "$(python3 - "$WORK/out" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['position'])
PY
)"

t_section "streams, status and error codes"

cli "$WORK/out" "$WORK/err" ok state ping
t_status "silent success exits 0" 0 cli "$WORK/out" "$WORK/err" silent state ping
t_empty "silent success prints nothing on stdout" "$(cat "$WORK/out")"
t_empty "silent success prints nothing on stderr" "$(cat "$WORK/err")"

t_status "JSON false is still a successful reply" 0 cli "$WORK/out" "$WORK/err" json-false state ping
t_eq "the boolean result is rendered by value, not truthiness" "false" "$(cat "$WORK/out")"

t_status "an unknown command exits 2" 2 cli "$WORK/out" "$WORK/err" unknown-route state ping
t_contains "the error names the code" "unknown-command" "$(cat "$WORK/err")"
t_empty "an error prints nothing on stdout" "$(cat "$WORK/out")"

t_status "a validation failure exits 2" 2 cli "$WORK/out" "$WORK/err" validation state ping
t_contains "the validation code" "invalid-argument" "$(cat "$WORK/err")"

t_status "a discoverable branch usage hint exits 2" 2 cli "$WORK/out" "$WORK/err" usage app call audioMixer
t_contains "the usage hint code" "usage" "$(cat "$WORK/err")"
t_contains "the usage hint names the branch help page" \
  "Use 'vb-shell app call audioMixer help' to see available options." "$(cat "$WORK/err")"
t_status "a JSON usage hint also exits 2" 2 cli "$WORK/out" "$WORK/err" usage --json app call audioMixer
t_status "a bare target usage hint also exits 2" 2 cli "$WORK/out" "$WORK/err" usage-target app
t_contains "the bare target hint names its help page" \
  "Use 'vb-shell app help' to see available options." "$(cat "$WORK/err")"
t_not_contains "no bare no-command diagnostic" "no command" "$(cat "$WORK/err")"
cli "$WORK/out" "$WORK/err" usage --json app call audioMixer
t_eq "the JSON usage hint keeps its code and message" \
  "usage|Use 'vb-shell app call audioMixer help' to see available options." \
  "$(python3 - "$WORK/err" <<'PY'
import json, sys
e = json.loads(open(sys.argv[1]).read())['error']
print(e['code'] + '|' + e['message'])
PY
)"

t_section "an informational help reply is RC 0 and prints help text"
t_status "instant help exits 0" 0 cli "$WORK/out" "$WORK/err" instant-help app
t_eq "stdout starts with the help usage" "Usage: vb-shell app" "$(head -1 "$WORK/out")"
t_contains "stdout has a Commands section" "Commands:" "$(cat "$WORK/out")"
t_not_contains "a target root prints no Examples section" "Examples:" "$(cat "$WORK/out")"
t_empty "stderr stays clean" "$(cat "$WORK/err")"
t_not_contains "no error line on stdout" "vb-shell: " "$(cat "$WORK/out")"

t_section "the CLI never renders a state field"
cli "$WORK/out" "$WORK/err" state-mixed --json audio stream n1.2 set 80
t_eq "state-only markers are dropped, other fields stay" "2" \
  "$(python3 - "$WORK/out" <<'PY'
import json, sys
print(len(json.loads(open(sys.argv[1]).read())))
PY
)"
cli "$WORK/out" "$WORK/err" state-mixed audio stream n1.2 set 80
t_not_contains "mixed payload has no state label" "state:" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" state-only bar module volume island open
t_empty "a state-only payload prints nothing" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" state-only --json menu item r1.1.1.2 activate
t_empty "a state-only JSON payload prints nothing" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" state-nested menu item r1.1.1.2 get
t_not_contains "nested state is dropped in text" "state:" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" state-nested --json menu item r1.1.1.2 get
t_not_contains "nested state is dropped in JSON" '"state"' "$(cat "$WORK/out")"
t_contains "the rest of the nested row stays" "n1.2" "$(cat "$WORK/out")"

t_status "an enum/ref miss exits 2" 2 cli "$WORK/out" "$WORK/err" bad-enum app toggle audioMicer
t_contains "the enum miss names the label" "unknown ID" "$(cat "$WORK/err")"
t_not_contains "the bad token is not echoed" "audioMicer" "$(cat "$WORK/err")"

t_status "unavailable exits 1" 1 cli "$WORK/out" "$WORK/err" unavailable state ping
t_status "no running Quickshell exits 1" 1 cli "$WORK/out" "$WORK/err" no-instance state ping
t_eq "missing Quickshell gets a plain diagnostic" "vb-shell: couldn't find Quickshell PID. Is Quickshell running?" "$(cat "$WORK/err")"
t_status "no running Quickshell in JSON exits 1" 1 cli "$WORK/out" "$WORK/err" no-instance --json log ping
t_eq "JSON keeps the unavailable code" \
  "{\"v\":1,\"ok\":false,\"error\":{\"code\":\"unavailable\",\"message\":\"couldn't find Quickshell PID. Is Quickshell running?\"}}" \
  "$(cat "$WORK/err")"
t_status "a transport timeout exits 1" 1 cli "$WORK/out" "$WORK/err" timeout state ping
t_contains "timeout is named on stderr" "timeout" "$(cat "$WORK/err")"
t_status "a malformed frame exits 1" 1 cli "$WORK/out" "$WORK/err" malformed state ping
t_contains "malformed framing is internal" "internal" "$(cat "$WORK/err")"
t_status "a native sentinel exits 1" 1 cli "$WORK/out" "$WORK/err" sentinel state ping
t_status "invalid UTF-8 on the reply exits 1" 1 cli "$WORK/out" "$WORK/err" invalid-utf8 state ping
t_empty "a failed reply never writes data to stdout" "$(cat "$WORK/out")"

t_status "--json errors exit with the same code" 2 cli "$WORK/out" "$WORK/err" validation --json state ping
t_eq "JSON mode writes only the diagnostic object to stderr" \
  '{"v":1,"ok":false,"error":{"code":"invalid-argument","message":"invalid-argument"}}' "$(cat "$WORK/err")"
t_empty "JSON mode leaves stdout clean on error" "$(cat "$WORK/out")"

# ---------------------------------------------------------------------------
t_section "paging: immutability, cursors and partial failure"

t_status "a partial paged failure exits 1" 1 cli "$WORK/out" "$WORK/err" partial-page --list
t_empty "a partial paged failure prints no first page" "$(cat "$WORK/out")"
for mode in stale-cursor expired-cursor wrong-instance; do
  t_status "a $mode cursor exits 1" 1 cli "$WORK/out" "$WORK/err" "$mode" --list
  t_empty "a $mode cursor prints nothing" "$(cat "$WORK/out")"
done

FAKE_QS_ADDED=1 cli "$WORK/out" "$WORK/err" ok --list
t_eq "an immutable snapshot collects every page" "0" "$?"
t_contains "the first page is printed" "systemUpdates" "$(cat "$WORK/out")"
t_contains "the second page is printed in order" "state" "$(cat "$WORK/out")"
t_not_contains "a concurrent model addition is not in the snapshot" "late-added" "$(cat "$WORK/out")"
t_not_contains "the fake addition never reaches output" "must not appear" "$(cat "$WORK/out")"

# ---------------------------------------------------------------------------
t_section "help aliases, layout and JSON shapes"

cli "$WORK/a" "$WORK/e" ok help settings fonts
cli "$WORK/b" "$WORK/e" ok settings help fonts
cli "$WORK/c" "$WORK/e" ok settings fonts help
t_eq "all three help spellings are byte-identical" "$(cat "$WORK/a")" "$(cat "$WORK/b")"
t_eq "trailing help is byte-identical too" "$(cat "$WORK/a")" "$(cat "$WORK/c")"
t_eq "a branch page starts with Usage" "Usage: vb-shell settings fonts reload" "$(head -1 "$WORK/a")"
t_not_contains "no ANSI escapes" "$(cat "$WORK/a")" $'\033'
t_not_contains "no tab" "$(cat "$WORK/a")" $'\t'
t_eq "no trailing blanks" "0" "$(grep -c '[[:blank:]]$' "$WORK/a")"
t_eq "exactly one final LF" "1" "$(python3 - "$WORK/a" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
print(1 if b.endswith(b'\n') and not b.endswith(b'\n\n') else 0)
PY
)"
t_contains "an example is indented two spaces" "  vb-shell settings fonts reload" "$(cat "$WORK/a")"
t_contains "Notes is present" "Notes:" "$(cat "$WORK/a")"

cli "$WORK/j" "$WORK/e" ok --json help settings fonts
t_eq "JSON help carries every declared key" \
  '["arguments", "commands", "examples", "notes", "options", "output", "path", "summary", "usage"]' \
  "$(python3 - "$WORK/j" <<'PY'
import json, sys
print(json.dumps(sorted(json.load(open(sys.argv[1])))))
PY
)"

cli "$WORK/l" "$WORK/e" ok --list
t_contains "the index preamble explains help once" "help [path...]" "$(cat "$WORK/l")"
cli "$WORK/i" "$WORK/e" ok --json --list
t_eq "index JSON has exactly common and targets" '["common", "targets"]' \
  "$(python3 - "$WORK/i" <<'PY'
import json, sys
print(json.dumps(sorted(json.load(open(sys.argv[1])))))
PY
)"
t_section "list rendering: described rows and target separation"
cli "$WORK/list" "$WORK/err" ok --list
t_eq "every target and child row has a real description" "0" "$(python3 - "$WORK/list" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
anchor = next(x for x in block if 'application search' in x)
col = anchor.index('application')
rows = [x for x in block if x.strip() and x[:col].strip()]
bad = 0
for line in rows:
    m = re.match(r'^(\s*\S.*) {2,}(\S.*)$', line)
    if not m or not m.group(2) or m.group(2) == '(no description)':
        bad += 1
print(bad)
PY
)"
t_eq "one global aligned description column" "1" "$(python3 - "$CLIENT" "$WORK/list" <<'PY'
import importlib.util, re, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
lines = open(sys.argv[2], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
cols = set()
anchor = next(x for x in block if 'application search' in x)
col = anchor.index('application')
for line in block:
    if not line.strip() or not line[:col].strip():
        continue
    m = re.match(r'^(\s*\S.*) {2,}(\S.*)$', line)
    cols.add(client.cells(line[:m.start(2)]))
print(len(cols))
PY
)"
t_eq "exactly one blank line between the six target groups" "5" "$(python3 - "$WORK/list" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
while block and not block[-1].strip():
    block.pop()
print(sum(1 for line in block if not line.strip()))
PY
)"
t_eq "no two blank lines in a row" "0" "$(python3 - "$WORK/list" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
print(sum(1 for a, b in zip(block, block[1:]) if not a.strip() and not b.strip()))
PY
)"
t_eq "the nested branch row keeps its own description" \
  "fonts reload Rescan installed system fonts" \
  "$(grep -F 'fonts' "$WORK/list" | sed -E 's/^[[:space:]]+//; s/  +/ /g' | head -1)"
t_eq "the target with many children lists every child" "9" "$(python3 - "$WORK/list" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = next(i for i, line in enumerate(lines) if line.startswith('  settings ')) + 1
n = 0
for line in lines[start:]:
    if not line.strip():
        break
    if line.startswith('    '):
        n += 1
print(n)
PY
)"
t_eq "the list ends with one LF and no trailing blank line" "1" "$(python3 - "$WORK/list" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
print(1 if b.endswith(b'\n') and not b.endswith(b'\n\n') else 0)
PY
)"

t_section "fixed 80-cell description budget, independent of terminal state"
( export COLUMNS=200; cli "$WORK/wide" "$WORK/err" ok --list )
( unset COLUMNS; cli "$WORK/defwidth" "$WORK/err" ok --list )
( export COLUMNS=40; cli "$WORK/small" "$WORK/err" ok --list )
t_eq "COLUMNS=200 output is identical to no COLUMNS" "0" \
  "$(cmp -s "$WORK/wide" "$WORK/defwidth"; echo $?)"
t_eq "COLUMNS=40 output is identical to no COLUMNS" "0" \
  "$(cmp -s "$WORK/small" "$WORK/defwidth"; echo $?)"
t_eq "a wide controlling terminal does not change piped output" "1" "$(python3 - "$CLIENT" "$FIXTURE" "$VIBRANIUM_DIR" "$WORK/defwidth" <<'PY'
import fcntl, os, pty, struct, subprocess, sys, termios
client_path, fixture_dir, root, reference = sys.argv[1:5]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 160, 0, 0))
env = os.environ.copy()
env.pop('COLUMNS', None)
env['PATH'] = fixture_dir + os.pathsep + env.get('PATH', '')
env['VIBRANIUM'] = root
env['FAKE_QS_MODE'] = 'ok'
env['PYTHONPYCACHEPREFIX'] = '/tmp/opencode/vb-shell-cli-pycache'

def controlling_tty():
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

proc = subprocess.Popen([sys.executable, '-B', client_path, '--list'],
                        stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        env=env, start_new_session=True, preexec_fn=controlling_tty)
out, _err = proc.communicate(timeout=10)
os.close(master)
os.close(slave)
print(1 if proc.returncode == 0 and out == open(reference, 'rb').read() else 0)
PY
)"
t_eq "no description line exceeds 80 cells after the description column" "0" "$(python3 - "$CLIENT" "$WORK/defwidth" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
lines = open(sys.argv[2], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
anchor = next(x for x in block if 'application search' in x)
col = client.cells(anchor[:anchor.index('application')])
print(sum(1 for line in block if line.strip() and client.cells(line[col:]) > 80))
PY
)"
t_eq "a long description wraps on fixed-width continuations" "1" "$(python3 - "$CLIENT" "$WORK/defwidth" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
lines = open(sys.argv[2], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
anchor = next(x for x in block if 'application search' in x)
col = client.cells(anchor[:anchor.index('application')])
first = next(i for i, x in enumerate(block) if x.strip().startswith('search  '))
cont = 0
for line in block[first + 1:]:
    if not line.strip():
        break
    if not line[:col].strip():
        cont += 1
print(1 if cont >= 2 else 0)
PY
)"

t_section "below-label fallback with a wide label column"
( unset COLUMNS; cli "$WORK/fallback" "$WORK/err" wide --list )
t_eq "wide labels put descriptions below at four spaces" "4" "$(python3 - "$CLIENT" "$WORK/fallback" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
line = next(x for x in open(sys.argv[2], encoding='utf-8') if 'This description is deliberately' in x)
print(client.cells(line[:line.index('This')]))
PY
)"
t_eq "fallback descriptions are also capped at 80 cells" "0" "$(python3 - "$CLIENT" "$WORK/fallback" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
lines = open(sys.argv[2], encoding='utf-8').read().splitlines()
start = lines.index('Targets:') + 1
block = lines[start:]
while block and not block[-1].strip():
    block.pop()
print(sum(1 for line in block if line.strip() and client.cells(line[4:]) > 80))
PY
)"

t_section "general descriptions are rendered verbatim"
t_contains "target summary is verbatim" \
  "application search, usage and plugins" "$(cat "$WORK/list")"
t_contains "a lowercase child stays lowercase" \
  "open the launcher" "$(cat "$WORK/list")"
t_contains "an already-capital child is untouched" \
  "Already capitalized" "$(cat "$WORK/list")"
t_contains "a leading non-letter prefix is kept" \
  "[preview] open palette" "$(cat "$WORK/list")"

cli "$WORK/jsonlist" "$WORK/err" ok --json --list
t_eq "text and JSON keep the same summary" "application search, usage and plugins" \
  "$(python3 - "$WORK/jsonlist" <<'PY'
import json, sys
targets = json.load(open(sys.argv[1]))['targets']
print(next(t['summary'] for t in targets if t['id'] == 'appLauncher'))
PY
)"

t_section "the -l child rows keep only literal words"
t_eq "no placeholder survives in the child rows" "0" "$(python3 - "$WORK/list" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = next(i for i, line in enumerate(lines) if line.startswith('  printers ')) + 1
print(sum(1 for line in lines[start:] if line.strip() and ('<' in line or '[' in line)))
PY
)"
t_eq "tokens and token order are unchanged" \
  "hold|release|cancel|log" \
  "$(python3 - "$WORK/list" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
start = next(i for i, line in enumerate(lines) if line.startswith('  printers ')) + 1
want = [('hold', 'Hold a job'), ('release', 'Release a job'),
        ('cancel', 'Cancel a job'), ('log', 'Follow logs by scope')]
out = []
for line in lines[start:]:
    if not line.strip():
        break
    for key, summary in want:
        if summary in line:
            label = line[:line.index(summary)].strip()
            out.append((key, re.sub(r'\s+', ' ', label)))
out.sort(key=lambda pair: [k for k, _ in want].index(pair[0]))
print('|'.join(label for _, label in out))
PY
)"
t_eq "a group with no placeholders is unchanged" "1" "$(python3 - "$CLIENT" "$WORK/list" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader('ipcclient', SourceFileLoader('ipcclient', sys.argv[1]))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
lines = open(sys.argv[2], encoding='utf-8').read().splitlines()
start = next(i for i, line in enumerate(lines) if line.startswith('  boot ')) + 1
seen = set()
for line in lines[start:]:
    if not line.strip():
        break
    if '<' in line or '[' in line:
        seen.add('placeholder')
print(0 if seen else 1)
PY
)"

t_section "exactly one table header row"
cli "$WORK/table" "$WORK/err" table state ping
t_eq "a three-column table prints one header line" "1" "$(python3 - "$WORK/table" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
headings = [[c.strip() for c in line.split(' | ')] for line in lines]
print(sum(1 for row in headings if row == ['Name', 'N', 'Tag']))
PY
)"
t_eq "header columns are in declared order" "Name|N|Tag" "$(python3 - "$WORK/table" <<'PY'
import sys
line = open(sys.argv[1], encoding='utf-8').read().splitlines()[0]
print('|'.join(c.strip() for c in line.split(' | ')))
PY
)"
t_eq "exactly one dashed separator follows the header" "1" "$(python3 - "$WORK/table" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
print(sum(1 for line in lines if re.fullmatch(r'-+(?:\+-+)+', line)))
PY
)"
t_eq "the separator is line two, after the single header" "1" "$(python3 - "$WORK/table" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
print(1 if re.fullmatch(r'-+(?:\+-+)+', lines[1]) else 0)
PY
)"
t_eq "separator boundaries align with the header" "6,10|6,10" "$(python3 - "$WORK/table" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
header = [i for i, c in enumerate(lines[0]) if c == '|']
sep = [i for i, c in enumerate(lines[1]) if c == '+']
print(','.join(map(str, header)) + '|' + ','.join(map(str, sep)))
PY
)"
t_eq "the separator spans the header width" "15" "$(python3 - "$WORK/table" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
print(len(lines[1]))
PY
)"
t_eq "the separator has no trailing blanks" "0" "$(python3 - "$WORK/table" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
print(1 if lines[1].rstrip() != lines[1] else 0)
PY
)"
t_eq "data rows follow the separator" "alpha" "$(python3 - "$WORK/table" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
print(lines[2].split(' | ')[0].strip())
PY
)"
t_eq "the table has no trailing blanks" "0" "$(grep -c '[[:blank:]]$' "$WORK/table")"

t_section "conventional flags"
cli "$WORK/help-short" "$WORK/err" ok -h
cli "$WORK/help-long" "$WORK/err" ok --help
t_eq "-h and --help are byte-identical local help" "0" \
  "$(cmp -s "$WORK/help-short" "$WORK/help-long"; echo $?)"
t_contains "-h does not select JSON" "Usage: vb-shell" "$(cat "$WORK/help-short")"
cli "$WORK/json-short" "$WORK/err" ok -j --list
cli "$WORK/json-long" "$WORK/err" ok --json --list
t_eq "-j and --json are byte-identical JSON" "0" \
  "$(cmp -s "$WORK/json-short" "$WORK/json-long"; echo $?)"
t_eq "-j help and --json help are byte-identical" "0" \
  "$(cli "$WORK/jh" "$WORK/err" ok -j help settings fonts; cli "$WORK/jsonh" "$WORK/err" ok --json help settings fonts; cmp -s "$WORK/jh" "$WORK/jsonh"; echo $?)"
cli "$WORK/jsoncall" "$WORK/err" ok -j state ping
t_eq "-j selects JSON, not help" '"ok"' "$(cat "$WORK/jsoncall")"
t_status "help with JSON is allowed" 0 cli "$WORK/out" "$WORK/err" ok -h -j
t_status "help and list remain mutually exclusive" 2 cli "$WORK/out" "$WORK/err" ok -h --list
t_status "short help and list remain mutually exclusive" 2 cli "$WORK/out" "$WORK/err" ok -l -h
t_status "--help with a positional argument is a usage error" 2 cli "$WORK/out" "$WORK/err" ok --help settings
t_status "--list with a positional argument is a usage error" 2 cli "$WORK/out" "$WORK/err" ok --list settings
t_status "an unknown global option is a usage error" 2 cli "$WORK/out" "$WORK/err" ok --bogus state ping
cli "$WORK/out" "$WORK/err" ok state get -h
assert_forwarded "-h after a path is literal data" \
  '{"argv": ["state", "get", "-h"], "kind": "call", "literalFrom": null, "v": 1}'

# ---------------------------------------------------------------------------
t_section "the native log route and the retained Bash wrapper"

cli "$WORK/out" "$WORK/err" ok log status
t_contains "log status is plain JSON rendered as a record" "level: info" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" ok log ping
t_eq "a valid log status proves liveness" "pong" "$(cat "$WORK/out")"
cli "$WORK/out" "$WORK/err" ok log help
t_contains "log help appends native prose under Notes" "a scope is derived" "$(cat "$WORK/out")"
t_eq "log help is called with no arguments" \
  '["-p", "'"$VIBRANIUM_DIR"'/shell", "ipc", "call", "log", "help"]' \
  "$(python3 - "$FAKE_QS_LOG" <<'PY'
import json, sys
line = open(sys.argv[1], encoding='utf-8').read().splitlines()[-1]
print(json.dumps(json.loads(line)['argv'][:6]))
PY
)"

t_eq "bin/vb-shell is the Python client" "1" \
  "$(head -1 "$VIBRANIUM_DIR/bin/vb-shell" | grep -Ec '^#!/usr/bin/env (-S )?python3([[:space:]]|$)')"
t_eq "the client has no Bash opt-in flag" "0" \
  "$(grep -c 'VB_SHELL_IPC' "$VIBRANIUM_DIR/bin/vb-shell")"
t_eq "the client reaches the fake transport" "ok" \
  "$(FAKE_QS_MODE=ok "$VIBRANIUM_DIR/bin/vb-shell" state ping 2>/dev/null)"

t_section "private IPC cache"
t_true "valid endpoints reuse the cache and stale endpoints preserve the binary verdict" python3 - "$CLIENT" "$WORK" <<'PYTEST'
import os
from pathlib import Path
import runpy
import socket
import stat
import sys
from unittest.mock import patch

script, work = map(Path, sys.argv[1:])
client = runpy.run_path(str(script))
runtime = work / "ipc"
runtime.mkdir(mode=0o700)
instance = "abc123"
byid = runtime / "quickshell" / "by-id" / instance
bypid = runtime / "quickshell" / "by-pid"
byid.mkdir(parents=True)
bypid.mkdir()
sock = byid / "ipc.sock"
pid = os.getpid()
link = bypid / str(pid)
link.symlink_to(byid)
config = str(work / "shell.qml")
directory = Path(client["_cache_dir"](str(runtime)))
cache = directory / (client["qs_path_id"](config) + ".json")
compat = {"v": 1, "qs": {"key": client["qs_binary_key"](script.stat()), "supported": True}}
record = {**compat, "socket": str(sock), "pid": pid, "instance": instance,
          "config": config, "display": client["qs_display"]()}
read = client["qs_cache_read"]
write = client["qs_cache_write"]

with socket.socket(socket.AF_UNIX) as listener:
    listener.bind(str(sock))
    write(str(cache), {}, record)
    assert read(str(cache)) == record
    with patch("os.scandir", side_effect=AssertionError("cache hit scanned the registry")):
        assert client["qs_endpoint"](str(runtime), config, record) == (str(sock), pid, True)
    validate = client["qs_cached_endpoint"]
    assert validate(str(runtime), config, {**record, "pid": 1_000_000_000}) is None
    link.unlink()
    link.symlink_to(byid.parent / "different-instance")
    assert validate(str(runtime), config, record) is None
    link.unlink()
    link.symlink_to(byid)
    sock.unlink()
    assert validate(str(runtime), config, record) is None
    client["qs_cache_invalidate"](str(cache), record)
    assert read(str(cache)) == compat
    # A late failure referring to the old snapshot must not clobber a newer one.
    updated = {**record, "pid": pid + 1}
    write(str(cache), compat, updated)
    client["qs_cache_invalidate"](str(cache), record)
    assert read(str(cache)) == updated

assert stat.S_IMODE(directory.stat().st_mode) == 0o700
assert stat.S_IMODE(cache.stat().st_mode) == 0o600
assert list(directory.iterdir()) == [cache]
assert client["_cache_dir"](str(work / "missing-runtime")) is None
PYTEST

t_true "startup warms the binary verdict without looking up a shell instance" python3 - "$CLIENT" "$WORK" <<'PYTEST'
from pathlib import Path
import runpy
import sys
from types import SimpleNamespace
from unittest.mock import patch

script, work = map(Path, sys.argv[1:])
client = runpy.run_path(str(script))
warm = client["warm_qs_cache"]
runtime = work / "warm-runtime"
runtime.mkdir(mode=0o700)
project = work / "warm-project"
config = project / "shell" / "shell.qml"
config.parent.mkdir(parents=True)
config.touch()
with patch.dict("os.environ", {"XDG_RUNTIME_DIR": str(runtime), "VIBRANIUM": str(project)}), patch.dict(
    warm.__globals__, {"find_program": lambda _: sys.executable}
), patch("os.scandir", side_effect=AssertionError("warmup looked up a shell")), patch(
    "subprocess.run",
    return_value=SimpleNamespace(returncode=0, stdout=b"Quickshell " + client["QS_VERSION"]),
) as probe:
    warm()
    warm()
    probe.assert_called_once()
    assert probe.call_args.args[0] == [sys.executable, "--version"]
cache, = (runtime / "vibranium" / "vb-shell").glob("*.json")
record = client["qs_cache_read"](str(cache))
assert record["qs"]["supported"] and "pid" not in record

# A verified incompatible binary should go directly to the CLI fallback,
# even if the native instance registry is large.
unsupported = {**record, "qs": {**record["qs"], "supported": False}}
client["qs_cache_write"](str(cache), record, unsupported)
with patch.dict("os.environ", {"XDG_RUNTIME_DIR": str(runtime)}), patch(
    "os.scandir", side_effect=AssertionError("incompatible binary scanned for an endpoint")
):
    assert client["qs_direct"](sys.executable, str(config.parent), "shell", "invoke", (), 0) is None
PYTEST

cli "$WORK/ping-a" "$WORK/err" ok state ping
cli "$WORK/ping-b" "$WORK/err" ok state ping
t_eq "repeated calls return byte-identical results" "0" \
  "$(cmp -s "$WORK/ping-a" "$WORK/ping-b"; echo $?)"

t_section "a cold time lookup waits for the clock probe"
COUNTER="$WORK/time-lookup.counter"
: >"$COUNTER"
FAKE_QS_MODE=time-lookup FAKE_QS_COUNTER="$COUNTER" \
  python3 -B "$CLIENT" appLauncher plugin command time lookup Moscow >"$WORK/out" 2>"$WORK/err"
t_eq "the cold lookup exits 0" "0" "$?"
t_contains "the landed clock is printed" "time: 00:49" "$(cat "$WORK/out")"
t_contains "the resolved city is printed" "city: Moscow" "$(cat "$WORK/out")"
t_eq "the accepted reply was retried exactly once" "2" "$(cat "$COUNTER")"
t_empty "the retry keeps stderr clean" "$(cat "$WORK/err")"

FAKE_QS_MODE=time-lookup-pending \
  python3 -B "$CLIENT" appLauncher plugin command time lookup Moscow >"$WORK/out" 2>"$WORK/err"
t_eq "a probe that never lands still exits 0" "0" "$?"
t_contains "the pending state is visible" "pending: true" "$(cat "$WORK/out")"
t_contains "the resolved zone is still printed" "timezone: Europe/Moscow" "$(cat "$WORK/out")"
t_empty "the pending reply keeps stderr clean" "$(cat "$WORK/err")"

t_section "bytecode cache"
t_true "help bytecode is deferred, warm caches are reused, and source edits invalidate them" python3 - "$CLIENT" "$WORK" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

source, work = map(Path, sys.argv[1:])
checkout = work / "bytecode"
checkout.mkdir()
script = checkout / "bin" / "vb-shell"
script.parent.mkdir()
script.write_bytes(source.read_bytes())
script.chmod(0o700)
runtime = work / "bytecode-runtime"
runtime.mkdir(mode=0o700)
env = {**os.environ, "XDG_RUNTIME_DIR": str(runtime)}
env.pop("PYTHONDONTWRITEBYTECODE", None)
cache_dir = runtime / "vibranium" / "vb-shell"

def help_output():
    return subprocess.check_output([script, "--help"], env=env)

assert subprocess.check_output([script, "state", "ping"], env=env) == b"ok\n"
core, = cache_dir.glob("vb-shell-*.marshal")
assert not core.name.endswith(".help.marshal")
core_inode = core.stat().st_ino
warmup = subprocess.run([script, "--warm-cache"], env=env, check=True, capture_output=True)
assert warmup.stdout == warmup.stderr == b""
assert {entry.name for entry in runtime.iterdir()} == {"vibranium"}
assert core.stat().st_ino == core_inode
caches = list(cache_dir.glob("vb-shell-*.marshal"))
assert len(caches) == 2
warm = [cache.stat().st_ino for cache in caches]
assert b"Usage: vb-shell [OPTIONS]" in help_output()
assert [cache.stat().st_ino for cache in caches] == warm
original = script.stat()
script.write_bytes(script.read_bytes().replace(b"Usage: vb-shell [OPTIONS]",
                                              b"Usage: vb-shell [CHANGED]", 1))
os.utime(script, ns=(original.st_atime_ns, original.st_mtime_ns))
assert b"Usage: vb-shell [CHANGED]" in help_output()
assert all(cache.stat().st_ino != inode for cache, inode in zip(caches, warm))
PY

t_summary
