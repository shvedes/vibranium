#!/bin/bash
# Suite: the client-owned `clipboard copy` routes.
#
# Nothing here starts the desktop shell. A fake `qs` confirms `clipboard ping`
# with the existing transport fixture; a fake `wl-copy` is the only external
# boundary and records its argv and raw stdin. The payload must never appear
# in the qs envelope, the client's streams, a temp file or an error message.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "clipboard-copy-ipc" "wl-copy argv/bytes, MIME validation, ping gate and no-leak rules"

CLIENT="$VIBRANIUM_DIR/bin/vb-shell"
FIXTURE="$TESTS_SHELL_DIR/suites/cli/fixtures"
PYCACHE="${TMPDIR:-/tmp}/opencode/clipboard-copy-ipc-pycache"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-clipboard-copy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

t_file "the Python client exists" "$CLIENT"
t_true "the client compiles" env PYTHONPYCACHEPREFIX="$PYCACHE" python3 -B -m py_compile "$CLIENT"

cat >"$WORK/bin/wl-copy" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"$WL_LOG"
cat >"$WL_IN"
FAKE
chmod +x "$WORK/bin/wl-copy"

export PATH="$FIXTURE:$WORK/bin:$PATH"
export VIBRANIUM="$VIBRANIUM_DIR"
export FAKE_QS_LOG="$WORK/qs.log"
export PYTHONPYCACHEPREFIX="$PYCACHE"
export WL_LOG="$WORK/wl.log"
export WL_IN="$WORK/wl.stdin"
: >"$FAKE_QS_LOG"
: >"$WL_LOG"
: >"$WL_IN"

copy() {
  local out="$1" err="$2" mode="${3:-ok}"
  shift 3
  : >"$WL_LOG"
  : >"$WL_IN"
  FAKE_QS_MODE="$mode" python3 -B "$CLIENT" "$@" >"$out" 2>"$err"
  return $?
}

t_section "payload never crosses the transport"
t_status "literal text is accepted" 0 copy "$WORK/out" "$WORK/err" ok clipboard copy text 'hello world'
t_eq "the literal reaches wl-copy stdin" "hello world" "$(cat "$WL_IN")"
t_eq "only flags are in wl-copy argv" "--type text/plain;charset=utf-8" "$(cat "$WL_LOG")"
t_empty "the client replies silently" "$(cat "$WORK/out")"
t_empty "stderr stays empty" "$(cat "$WORK/err")"
t_not_contains "the payload is not in the qs envelope" "hello world" "$(cat "$FAKE_QS_LOG")"
t_eq "clipboard ping was confirmed first" \
  '["clipboard", "ping"]' "$(python3 - "$FAKE_QS_LOG" <<'PY'
import json, sys
lines = [json.loads(x) for x in open(sys.argv[1], encoding='utf-8').read().splitlines()]
req = json.loads(lines[0]['argv'][-1][len("v1:"):])
print(json.dumps(req['argv']))
PY
)"

t_section "stdin, literal dash and text validation"
t_status "stdin text is accepted" 0 bash -c "printf 'from stdin' | FAKE_QS_MODE=ok python3 -B '$CLIENT' clipboard copy text -"
t_eq "stdin bytes reach wl-copy" "from stdin" "$(cat "$WL_IN")"
: >"$WL_LOG"; : >"$WL_IN"
t_status "an empty literal is allowed" 0 copy "$WORK/out" "$WORK/err" ok clipboard copy text ''
t_empty "empty text writes nothing" "$(cat "$WL_IN")"
t_status "-- makes a dash literal" 0 copy "$WORK/out" "$WORK/err" ok clipboard copy text -- -
t_eq "the literal dash is not stdin" "-" "$(cat "$WL_IN")"
t_status "invalid UTF-8 on stdin is refused" 2 bash -c "printf '\\377' | FAKE_QS_MODE=ok python3 -B '$CLIENT' clipboard copy text -"

t_section "URI and file routes"
t_status "an absolute URI is accepted" 0 copy "$WORK/out" "$WORK/err" ok clipboard copy uri 'https://example.org/a'
t_eq "URI bytes carry CRLF" "$(printf 'https://example.org/a\r\n')" "$(cat "$WL_IN")"
t_eq "the URI MIME is exact" "--type text/uri-list" "$(cat "$WL_LOG")"
t_status "a URI with an unescaped space is refused" 2 copy "$WORK/out" "$WORK/err" ok clipboard copy uri 'https://x/a b'
t_contains "the refusal names an argument error" "invalid-argument" "$(cat "$WORK/err")"
t_status "a relative URI is refused" 2 copy "$WORK/out" "$WORK/err" ok clipboard copy uri 'no-scheme'
t_eq "no writer started for a bad URI" "" "$(cat "$WL_LOG")"
printf 'payload \342\230\203\n' >"$WORK/my notes.txt"
t_status "a file with spaces is accepted" 0 copy "$WORK/out" "$WORK/err" ok clipboard copy file "$WORK/my notes.txt"
t_eq "path segments are escaped" "$(python3 - "$WORK/my notes.txt" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).resolve().as_uri() + "\r")
PY
)" "$(cat "$WL_IN")"
t_status "a missing path is refused" 2 copy "$WORK/out" "$WORK/err" ok clipboard copy file "$WORK/missing"
t_not_contains "the error carries no path" "$WORK/missing" "$(cat "$WORK/err")"

t_section "image magic and size"
python3 - "$WORK/ok.png" <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + b'X' * 64)
PY
t_status "a matching PNG is accepted" 0 bash -c "cat '$WORK/ok.png' | FAKE_QS_MODE=ok python3 -B '$CLIENT' clipboard copy image image/png -"
t_eq "the declared MIME is used verbatim" "--type image/png" "$(cat "$WL_LOG")"
t_eq "bytes are unchanged" "$(cat "$WORK/ok.png" | base64 -w0)" "$(cat "$WL_IN" | base64 -w0)"
: >"$WL_LOG"
t_status "mismatched magic is refused" 2 bash -c "printf 'not a png' | FAKE_QS_MODE=ok python3 -B '$CLIENT' clipboard copy image image/png -"
t_eq "no writer started for bad magic" "" "$(cat "$WL_LOG")"
t_status "an unsupported MIME is a usage error" 2 copy "$WORK/out" "$WORK/err" ok clipboard copy image image/svg+xml -
t_status "an oversized image is refused" 1 bash -c "python3 -c 'import sys; sys.stdout.buffer.write(b\"x\" * (32 * 1024 * 1024 + 1))' | FAKE_QS_MODE=ok python3 -B '$CLIENT' clipboard copy image image/png -"

t_section "generic failures, no payload echoes"
t_status "an unavailable clipboard is reported" 1 copy "$WORK/out" "$WORK/err" unavailable clipboard copy text 'secret text'
t_contains "the error is generic" "unavailable" "$(cat "$WORK/err")"
t_not_contains "the payload is not echoed on stderr" "secret text" "$(cat "$WORK/err")"
t_eq "no writer started without a confirmed ping" "" "$(cat "$WL_LOG")"
t_status "an unknown copy form is resolved by the shell" 2 copy "$WORK/out" "$WORK/err" unknown-route clipboard copy nope x
t_contains "the shell error is propagated" "unknown-command" "$(cat "$WORK/err")"
mkdir -p "$WORK/empty"
t_status "a missing writer is a generic backend error" 1 env PATH="$FIXTURE:$WORK/empty" \
  /usr/bin/python3 -B "$CLIENT" clipboard copy text 'secret text'

t_summary
