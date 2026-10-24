#!/bin/bash
# Suite: the harness itself.
#
# A test suite that cannot fail is worse than no test suite, and this one
# guards against exactly that. Everything else in tests/shell trusts
# lib/harness.sh and lib/qmlprobe.sh to report a failure faithfully; that trust
# is only worth something if it is itself tested.
#
# Each case here runs a throwaway suite as a subprocess and asserts on its exit
# status and on the result file it leaves behind. The throwaway suites go to a
# temp dir and are removed, so nothing outside tests/shell/lib is touched and
# the runner never sees a deliberately failing suite.
#
# The exit-code contract under test, from harness.sh:
#   0   every assertion passed
#   1   at least one assertion failed
#   77  BLOCKED - the suite could not run here
# A suite that exits 0 while having recorded a failure is the failure mode this
# file exists to make impossible.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

# The throwaway suites are separate processes that source the real kit, so
# they need the path to it. Exported rather than interpolated so the
# heredocs below stay readable and a moved checkout does not break them.
export TESTS_SHELL_DIR

t_init "harness" "the assertion kit fails when it should, and reports it faithfully"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-harness-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# _case <name> <expected-exit> <assertion-body>
#
# Writes a suite that sources the real harness, runs the body, and returns
# through t_summary; runs it in a subprocess with a private results file; then
# asserts the exit status and leaves the results file in R.
#
# R is a global, not a command substitution, on purpose: a function whose last
# statement runs `t_ok` cannot be called inside `$(...)` - the counter
# increments happen in the subshell and are thrown away, so the parent would
# see no assertions at all and report a suite that asserts nothing. That is
# the same trap as a subshell-scoped temp path, and it is why this suite
# checks its own output rather than trusting it.
R=""
R_LOG=""

_case() {
  local name="$1" want_rc="$2" body="$3"
  local suite="$WORK/$name.sh"
  R="$WORK/$name.results"
  R_LOG="$WORK/$name.log"

  {
    printf '#!/bin/bash\n'
    printf 'source "$TESTS_SHELL_DIR/lib/lib.sh"\n'
    printf 'source "$TESTS_SHELL_DIR/lib/harness.sh"\n'
    printf 't_init "%s" "throwaway fixture"\n' "$name"
    printf 't_section "self-test"\n'
    printf '%s\n' "$body"
    printf 't_summary\n'
  } >"$suite"

  : >"$R"
  SHELL_TEST_RESULTS="$R" bash "$suite" >"$R_LOG" 2>&1
  local rc=$?

  if [[ $rc != "$want_rc" ]]; then
    t_no "$name: exit status" "$(printf 'expected exit %s, got %s\n--- suite output ---\n%s' \
      "$want_rc" "$rc" "$(cat "$R_LOG")")"
    return 1
  fi
  t_ok "$name: exit status is $want_rc"
  return 0
}

# _write <name> <body> - the same fixture writer, for the cases that assert on
# the output rather than through t_summary.
_write() {
  local name="$1" body="$2"
  {
    printf '#!/bin/bash\n'
    printf 'source "$TESTS_SHELL_DIR/lib/lib.sh"\n'
    printf 'source "$TESTS_SHELL_DIR/lib/harness.sh"\n'
    printf 't_init "%s" "throwaway fixture"\n' "$name"
    printf '%s\n' "$body"
  } >"$WORK/$name.sh"
}

# _count <results-file> <status>
_count() {
  awk -F'\t' -v s="$2" '$1 == s' "$1" 2>/dev/null | wc -l | tr -d ' '
}

t_section "a suite whose assertions all pass exits 0"
if _case all-pass 0 "t_eq \"a label\" \"x\" \"x\"
t_ne \"another\" \"y\" \"x\"
t_contains \"has it\" \"ell\" \"hello\"
t_not_contains \"has not\" \"zzz\" \"hello\"
t_match \"regex\" 'h.llo' \"hello\"
t_true \"a true command\" true
t_false \"a false command\" false
t_status \"exit 0\" 0 true"; then
  t_eq "all eight assertions are recorded" "8" "$(_count "$R" PASS)"
  t_eq "none recorded a failure" "0" "$(_count "$R" FAIL)"
fi

t_section "a single failing assertion is enough to fail the suite"
if _case one-fail 1 "t_eq \"passes\" \"x\" \"x\"
t_eq \"fails\" \"expected\" \"actual\"
t_eq \"passes again\" \"x\" \"x\""; then
  t_eq "the passing assertions are still recorded" "2" "$(_count "$R" PASS)"
  t_eq "the failing one is recorded as FAIL" "1" "$(_count "$R" FAIL)"
  t_eq "and the results file names it by label" "1" \
    "$(awk -F'\t' '$1 == "FAIL" && $3 == "fails"' "$R" | wc -l | tr -d ' ')"
  # The detail is what a reader debugs from, so it must carry both sides.
  t_contains "the detail names what was expected" "expect:" "$(awk -F'\t' '$1 == "FAIL"' "$R")"
  t_contains "the detail names what was actually got" "got:" "$(awk -F'\t' '$1 == "FAIL"' "$R")"
  t_eq "the section is recorded too" "self-test" "$(awk -F'\t' '$1 == "FAIL" { print $2 }' "$R")"
fi

t_section "a suite that cannot run exits 77, not 0 and not 1"
# BLOCKED must never be mistaken for a pass. This is the single most important
# property of the exit-code contract.
if _case blocked 77 "t_block \"no compositor in this environment\""; then
  t_eq "and the reason is recorded" "1" "$(_count "$R" BLOCKED)"
  t_eq "no assertion is recorded as passed" "0" "$(_count "$R" PASS)"
  t_eq "and none as failed" "0" "$(_count "$R" FAIL)"
fi

t_section "a note is not a pass and not a failure"
if _case note-only 0 "t_note \"a documented difference, not an assertion\"
t_eq \"a real assertion\" \"x\" \"x\""; then
  t_eq "the note is recorded as NOTE" "1" "$(_count "$R" NOTE)"
  t_eq "and is not counted as an assertion" "1" "$(_count "$R" PASS)"
  t_eq "both rows exist" "2" "$(wc -l <"$R" | tr -d ' ')"
fi

t_section "a skip is never a pass"
if _case skip-only 0 "t_skip \"a behaviour that needs a compositor\" \"no compositor here\"
t_eq \"a real assertion\" \"x\" \"x\""; then
  t_eq "the skip is recorded as SKIP" "1" "$(_count "$R" SKIP)"
  t_eq "and not as a pass" "1" "$(_count "$R" PASS)"
  t_eq "and it does not by itself fail the suite" "0" "$(_count "$R" FAIL)"
fi

t_section "every assertion form actually discriminates"
# A harness whose assertions cannot fail is the failure mode this suite exists
# for, so each form is checked against a deliberately wrong value and each
# must produce a FAIL row. There are seventeen forms.
if _case discriminates 1 "t_eq \"eq\" \"a\" \"b\"
t_ne \"ne\" \"a\" \"a\"
t_contains \"contains\" \"a\" \"b\"
t_not_contains \"not_contains\" \"b\" \"b\"
t_match \"match\" 'a+' \"bbb\"
t_not_match \"not_match\" 'b+' \"bbb\"
t_true \"true\" false
t_false \"false\" true
t_status \"status\" 0 false
t_empty \"empty\" \"x\"
t_not_empty \"not_empty\" \"\"
t_file \"file\" \"/nonexistent/path/xyz\"
t_no_file \"no_file\" \"/etc/hostname\"
t_count \"count\" \"5\" \"4\"
t_sorted \"sorted\" \"b
a\"
t_unique \"unique\" \"a
a\"
t_lines \"lines\" \"3\" \"2\" \"a
b\""; then
  t_eq "all seventeen forms failed" "17" "$(_count "$R" FAIL)"
  t_eq "and each carried a distinct label" "17" \
    "$(awk -F'\t' '$1 == "FAIL" { print $3 }' "$R" | sort -u | wc -l | tr -d ' ')"
fi

t_section "the results file is well-formed"
# run-all.sh parses this file to classify a suite, so a malformed row would
# make a real failure invisible rather than loud.
t_eq "every row has exactly four tab-separated fields" "0" \
  "$(awk -F'\t' 'NF != 4 { n++ } END { print n + 0 }' "$R")"
t_eq "the status column only holds known values" "0" \
  "$(awk -F'\t' '$1 != "PASS" && $1 != "FAIL" && $1 != "SKIP" && $1 != "NOTE" && $1 != "BLOCKED" { n++ } END { print n + 0 }' "$R")"
t_eq "every row carries a label" "0" \
  "$(awk -F'\t' '$3 == "" { n++ } END { print n + 0 }' "$R")"
t_eq "the file ends with a newline, so the last row is complete" "1" \
  "$(tail -c1 "$R" | od -An -c | tr -d ' \n' | grep -c '\\n')"

t_section "a suite that dies before it can assert is not a pass"
# A suite that aborts part-way - a missing command, a `set -e` trip - never
# reaches t_summary. It must not be mistaken for a green suite by anything
# reading the exit status, and it must not have recorded a pass on the way.
_write dies 'set -e
nonexistent_function_that_will_throw
t_summary'
: >"$WORK/dies.results"
SHELL_TEST_RESULTS="$WORK/dies.results" bash "$WORK/dies.sh" >"$WORK/dies.log" 2>&1
rc=$?
t_ne "a suite that dies does not exit 0" "0" "$rc"
t_eq "and records no passing assertion" "0" "$(_count "$WORK/dies.results" PASS)"

t_section "a suite with a missing tool blocks rather than fails"
# require_tools is the gate that keeps "awk is not installed" from being
# reported as seventeen behavioural failures.
_write notool 'require_tools definitely-not-a-real-tool-xyz
t_eq "never reached" "x" "y"
t_summary'
: >"$WORK/notool.results"
SHELL_TEST_RESULTS="$WORK/notool.results" bash "$WORK/notool.sh" >"$WORK/notool.log" 2>&1
rc=$?
t_eq "it exits BLOCKED" "77" "$rc"
t_match "and says which tool" 'definitely-not-a-real-tool-xyz' "$(cat "$WORK/notool.log")"
t_eq "with no assertion recorded either way" "0" \
  "$(awk -F'\t' '$1 == "PASS" || $1 == "FAIL"' "$WORK/notool.results" | wc -l | tr -d ' ')"

t_section "the platform gate is a real gate"
# The suite pins the Quickshell and Qt pair in lib/lib.sh. platform_mismatch
# must report no mismatch here, and a real mismatch when the expected version
# is absurd.
if platform_mismatch; then
  t_no "the pinned platform matches this host" "platform_mismatch reported: $(platform_mismatch)"
else
  t_ok "the pinned platform matches this host"
fi

_mismatch_for() {
  REQUIRED_QUICKSHELL_VERSION="$1" REQUIRED_QT_VERSION="$2" platform_mismatch
}
if _mismatch_for "0.0.0-not-a-version" "0.0.0"; then
  t_ok "an impossible Quickshell version is reported as a mismatch"
else
  t_no "an impossible Quickshell version is reported as a mismatch" "platform_mismatch returned clean"
fi
if _mismatch_for "$REQUIRED_QUICKSHELL_VERSION" "0.0.0"; then
  t_ok "an impossible Qt version is reported as a mismatch"
else
  t_no "an impossible Qt version is reported as a mismatch" "platform_mismatch returned clean"
fi
t_eq "the gate compares patch releases, so 0.3.0 is not $REQUIRED_QUICKSHELL_VERSION" "0" \
  "$(_mismatch_for "0.3.0" "$REQUIRED_QT_VERSION" >/dev/null; echo $?)"
t_note "hasVersion()/hasQtVersion() are deliberately not used as the gate: they do not verify patch releases, so a different patch would still satisfy the pin"

t_section "the probe harness reports a probe that never finished"
# A QML probe that dies during construction prints no sentinel. qp_run must
# return non-zero for that, or every assertion it feeds would read as an empty
# value and silently pass.
if command -v qs >/dev/null 2>&1 && ! platform_mismatch; then
  source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

  cat >"$WORK/dying-probe.qml" <<'QML'
import QtQuick
Item { Component.onCompleted: { this_is_not_defined_xyz() } }
QML
  if qp_run "$WORK/dying-probe.qml" 10; then
    t_no "a probe that throws before its sentinel is reported as unfinished" "qp_run returned 0"
  else
    t_ok "a probe that throws before its sentinel is reported as unfinished"
  fi
  t_eq "and it emitted no values at all" "0" "$(grep -c '##KV##' "$_QP_OUT" 2>/dev/null | tr -d ' ')"

  cat >"$WORK/good-probe.qml" <<'QML'
import QtQuick
Item { Component.onCompleted: { console.log("##KV## probe.value=42"); console.log("##DONE##") } }
QML
  if qp_run "$WORK/good-probe.qml" 15; then
    t_ok "qp_run returns 0 when the sentinel arrives"
    t_eq "and the value it printed is readable" "42" "$(qp_get probe.value)"
    if qp_probe_ran probe.value; then
      t_ok "qp_probe_ran confirms a key that was printed"
    else
      t_no "qp_probe_ran confirms a key that was printed" "it reported false for a printed key"
    fi
  else
    t_no "qp_run returns 0 when the sentinel arrives" "$(qp_out)"
  fi
  # The distinction that keeps a broken probe from looking like a passing one.
  t_eq "a key the probe never printed reads as empty" "" "$(qp_get never.printed)"
  if qp_probe_ran never.printed; then
    t_no "qp_probe_ran is false for a key that was not printed" "it reported true"
  else
    t_ok "qp_probe_ran is false for a key that was not printed"
  fi
  qp_teardown
else
  t_skip "the probe harness" "qs is unavailable on this host"
fi

t_section "the node kit shares the exit-code contract"
# The JS suites and the bash suites must be indistinguishable to the runner,
# which is the whole reason the two kits emit the same result format.
if command -v node >/dev/null 2>&1; then
  cat >"$WORK/good.test.mjs" <<EOF
import { suite, section, group, eq, finish } from '$TESTS_SHELL_DIR/lib/assert.mjs'
suite('good')
section('a group')
group('a passing case', () => { eq('equal', 1, 1) })
finish()
EOF
  cat >"$WORK/bad.test.mjs" <<EOF
import { suite, section, group, eq, finish } from '$TESTS_SHELL_DIR/lib/assert.mjs'
suite('bad')
section('a group')
group('a failing case', () => { eq('not equal', 1, 2) })
finish()
EOF
  cat >"$WORK/skipped.test.mjs" <<EOF
import { suite, section, group, skip, finish } from '$TESTS_SHELL_DIR/lib/assert.mjs'
suite('skipped')
section('a group')
group('a skipped case', () => { skip('needs a compositor', 'no compositor here') })
finish()
EOF

  : >"$WORK/good.results"
  SHELL_TEST_RESULTS="$WORK/good.results" node "$WORK/good.test.mjs" >/dev/null 2>&1
  t_eq "a passing node suite exits 0" "0" "$?"
  t_eq "and records its pass" "1" "$(_count "$WORK/good.results" PASS)"

  : >"$WORK/bad.results"
  SHELL_TEST_RESULTS="$WORK/bad.results" node "$WORK/bad.test.mjs" >/dev/null 2>&1
  t_eq "a failing node suite exits 1" "1" "$?"
  t_eq "and records its failure" "1" "$(_count "$WORK/bad.results" FAIL)"
  t_eq "with the same four-field format" "0" \
    "$(awk -F'\t' 'NF != 4 { n++ } END { print n + 0 }' "$WORK/bad.results")"

  : >"$WORK/skipped.results"
  SHELL_TEST_RESULTS="$WORK/skipped.results" node "$WORK/skipped.test.mjs" >/dev/null 2>&1
  t_eq "a node suite with only a skip exits 0" "0" "$?"
  t_eq "and records the skip as SKIP" "1" "$(_count "$WORK/skipped.results" SKIP)"
  t_eq "and not as a pass" "0" "$(_count "$WORK/skipped.results" PASS)"
else
  t_skip "the node assertion kit" "node is not on PATH"
fi

t_section "the JS loader reproduces QML's own rules"
# loadLib is what makes the pure-JS suites possible, and its two rules - that
# top-level declarations are the namespace, and that `.import` binds a
# namespace under its alias - are QML semantics rather than node semantics. A
# loader that quietly got them wrong would make every JS suite test the wrong
# thing while still going green.
if command -v node >/dev/null 2>&1; then
  node --input-type=module -e "
    import { loadLib, loadPlugin } from '$TESTS_SHELL_DIR/lib/qmlloader.mjs'
    import fs from 'node:fs'
    const out = []
    const ok = (label, cond) => out.push((cond ? 'PASS' : 'FAIL') + '\t' + label)

    // A .pragma library exposes its top-level declarations, with no exports.
    const su = loadLib('$SHELL_DIR/common/text/StringUtils.js')
    ok('a top-level function becomes a namespace member', typeof su.shellQuote === 'function')
    ok('a .pragma library has no CommonJS exports', su.exports === undefined)

    // A plain JS file with no .pragma library still loads the same way.
    const wt = loadLib('$SHELL_DIR/features/wallpaper/WallpaperTrans.js')
    ok('a file without .pragma library also loads', typeof wt.normalizeKind === 'function')

    // .import binds a namespace under its alias, and does not re-export it.
    const shot = loadLib('$SHELL_DIR/common/capture/ShotLib.js')
    ok('a library with an .import loads without throwing', typeof shot.mimeForPath === 'function')
    ok('its .import alias is not re-exported', shot.SU === undefined)

    // CalendarLib publishes a CommonJS export list; that is honoured.
    const cal = loadLib('$SHELL_DIR/common/ui/CalendarLib.js')
    ok('a CommonJS export list is honoured', typeof cal.dateKey === 'function')

    // A plugin is evaluated the way PluginInstance.qml evaluates it.
    const p = loadPlugin('$SHELL_DIR/features/launcher/plugins/calc/main.js', {})
    ok('a plugin exposes items()', typeof p.items === 'function')
    ok('a plugin exposes activate()', typeof p.activate === 'function')
    ok('a plugin declares nothing else', Object.keys(p).sort().join(',') === 'activate,init,items')

    // The three rejection paths from PluginInstance.qml.
    const os = (await import('node:os')).tmpdir()
    const made = []
    const bad = (src) => {
      const f = os + '/vb-loader-selfcheck.js'
      made.push(f)
      fs.writeFileSync(f, src)
      try { loadPlugin(f, {}); return 'accepted' } catch (e) { return e.message }
    }
    ok('a plugin that assigns nothing is refused',
      bad('var x = 1').includes('did not assign VibraniumPlugin'))
    ok('a plugin without items() is refused',
      bad('VibraniumPlugin = { activate: function(){} }').includes('items/activate must be functions'))
    ok('a plugin that throws is refused', bad('throw new Error(\"boom\")').length > 0)
    for (const f of made) if (fs.existsSync(f)) fs.unlinkSync(f)

    console.log(out.join('\n'))
  " >"$WORK/loader.results" 2>"$WORK/loader.err"
  rc=$?
  if ((rc == 0)); then
    t_eq "every loader rule holds" "0" "$(_count "$WORK/loader.results" FAIL)"
    t_true "and the loader check asserted something real" \
      test "$(_count "$WORK/loader.results" PASS)" -ge 9
  else
    t_no "the loader self-check ran" "$(cat "$WORK/loader.err")"
  fi
else
  t_skip "the JS loader rules" "node is not on PATH"
fi

t_section "the suite guards itself"
# If this file asserted nothing, it would exit 0 and be reported as a pass,
# which is the exact failure mode it exists to prevent. A floor on the number
# of assertions is the cheapest way to make that impossible.
t_note "this suite exists so that a broken harness cannot report a green run; it deliberately contains throwaway failing fixtures, which is why its own failure count is 0 while its fixtures record many"
t_true "the suite records a substantial number of assertions" test "$T_TOTAL" -ge 30

t_summary
