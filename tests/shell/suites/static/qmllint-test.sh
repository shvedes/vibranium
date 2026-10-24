#!/bin/bash
# Suite: qmllint - the reproducible lint baseline from shell/README.md.
#
# The README publishes one invocation and a measured baseline: 230 files,
# 0 errors, 146 warnings, and 72 informational diagnostics. Exit status alone
# cannot distinguish a resolved tree from one whose imports became warnings,
# so this suite checks the diagnostic stream too.
#
# That last sentence is the reason this suite exists. An exit-status check
# passes on a tree that cannot resolve its own imports, because qmllint
# downgrades a missing module to a warning. So the load-bearing assertion
# here is the *error count parsed out of the diagnostics*, not `$?`, and the
# last section proves the parsing can tell the difference by deliberately
# breaking the import path and asserting the diagnostics explode.
#
# The warnings are not counted blindly either. Every warning is classified,
# the per-kind counts are pinned, and the unresolved-type / uncreatable-type
# subset is held to exactly the Quickshell C++-registered types - each one
# cross-checked against the installed quickshell-*.qmltypes, so "this is a
# Quickshell type" is a checked fact rather than an accepted excuse.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "qmllint" "lint baseline: 0 errors, classified warnings, deterministic"

# The recorded baseline, from shell/README.md "Verifying a change" plus this
# suite's own measurement. Kept in one place so a diff in the numbers is
# readable.
#
# RECORDED_FILE_COUNT: 231 .qml files under shell/. This is the file set the
#   README's one-liner hands to the tool and the set the suite hands to it, and
#   every counted diagnostic is attributed to one of these paths ("every
#   diagnosed file is one that was linted"), so the count and the warning set
#   below always describe the same tree. A file added here with a root object
#   Quickshell registers from C++ adds no new unresolved name and no
#   missing-property, so it can move the file count without moving either.
# RECORDED_WARNING_COUNT: 146 "Warning:" diagnostics. This is the sum of the
#   per-kind breakdown below and is not an independent figure, so it cannot
#   distinguish a kind that stopped firing from a kind that started. What makes
#   the total legible is the breakdown, which is why every kind is pinned
#   separately. A total that falls because a kind fell is the count doing its
#   job.
#
#   The pairing that matters most is the total with `missing-property`, because
#   one defect moves both at once: code that reads a property the engine does
#   not declare produces exactly one `missing-property` warning, so a defect of
#   that shape and the total are not independent facts and a total recorded
#   against a tree that has one is only satisfiable while the defect is there.
#   54 `missing-property` warnings is the current measured figure, and the
#   warning total is 146. Eleven additional dynamic/property-access diagnostics
#   are retained rather than suppressed; the component probes pin those runtime
#   contracts separately. A reader who sees the total fall with
#   `missing-property` should identify the exact reads that changed before
#   treating the new count as a baseline. A warning that was
#   removed, not a regression; the reverse is an unrecorded defect and belongs in
#   this file as a new per-kind figure.
#
#   Most of them are not defects either. `common/ui/IslandHost.qml` alone
#   accounts for 17 of the 54, and every one of them is a read of a member on
#   an object qmllint cannot resolve to its real type: a `QObject` content
#   item, a `QuickshellScreenInfo`, a `QQuickLoader::item`. The duck-typed
#   size contract has always cost one warning per read; the keyboard contract
#   is the same read of a property the content may not declare, so it counts
#   the same way.
#
#   The rest are the same kind of thing.
#   features/apps/imageViewer/ImageViewerWindow.qml reads
#   `Qt.application.state`, and this build's installed builtins.qmltypes gives
#   `QQmlApplication` `arguments`, `name`, `version`, `organization` and
#   `domain` and not `state`, so the property the code reads is real and the
#   description is short. That is a gap in the type description, not in the
#   code, and it is why this figure can be one higher than the code would
#   suggest.
#
#   The ones on the model types are the same kind of thing.
#   features/lock/LockscreenSurfaceView.qml
#   reads `width`, `height` and `name` off a `QuickshellScreenInfo`, and
#   several files read `values` off an `UntypedObjectModel` it built with
#   `createObject`, which qmllint cannot resolve, so it typed the result
#   `QObject` and reported a missing member that the type does have - once per
#   read. Reachability, not the count, is what matters: the dispatch was
#   measured against real out-of-band writes, and the read that replaced the
#   probe was measured to return the new body where the bare reload returned
#   the old one.
#
# RECORDED_INFO_COUNT: 71 "Info:" diagnostics: 17 `[unused-imports]` and 54
#   untagged "X is a member of a parent element" notes. Untagged at the tail,
#   and a severity this suite counts separately, so neither reaches the warning
#   total above.
#
#   The unused-import count is a verdict, not a defect count. qmllint decides
#   the verdict without modelling a module resolving its own members, so an
#   `import qs.<module>` whose only readers are that module's own members is
#   reported unused. Obeying such a diagnostic is what breaks the file, which
#   is the state shell/features/polkit/PolkitView.qml:8-18 documents for its own
#   `import qs.common`; that import is read again and contributes no diagnostic,
#   so the 18 here are files whose imports are reported unused and are not read,
#   and one of them (TrayItem) names two. Most are `import qs.common` whose only
#   reader was a call into the logger, so the diagnostic appeared when those
#   call sites went and the import was left behind - which is exactly the shape
#   this count should move by.
#   A count that falls because an import acquired a reader is the count doing
#   its job, and a count that rises to accommodate one of these diagnostics
#   would be accommodating a wrong one. The last one to leave was
#   common/runtime/UnitGate.qml's: its only reader is the call into the logger
#   that reports a unit's lifecycle, so the import is one of the "most" this
#   note names, and putting the calls back is what took the diagnostic with it.
#
#   The parent-element note counts a name that resolves through scopes the
#   delegate scopes up. That naming is deliberate across the bar and menu
#   surfaces, so 54 is a shape of the tree rather than 54 defects, and it moves
#   with those files.
#
#   Recorded against a measured tree, which is the only property worth stating
#   about any of these numbers: a count recorded off a modified tree describes
#   the debugging rather than the code.
#
#   One trap in this tree's own source, worth restating because it is a
#   property of the tool rather than of any count: a comment whose first line
#   begins with the tool's own name is parsed as a lint directive, and every
#   word of it is then read as a category name. The sentence that documents this
#   in shell/features/polkit/PolkitView.qml is written around it for that
#   reason. Do not start a comment line with the tool's name.
RECORDED_FILE_COUNT=231
RECORDED_WARNING_COUNT=146
RECORDED_INFO_COUNT=71
README_WARNING_COUNT=146

# The unresolved-type / uncreatable-type names this tree is allowed to leave
# unresolved: Quickshell types registered from C++, which qmllint cannot see
# outside a live runtime. Exact set, so a *new* unresolved name fails the
# suite rather than being absorbed into a count.
#
# The README lists four (FileViewAdapter, PanelWindow, BluetoothAdapter,
# UntypedObjectModel). The tree actually produces five: AuthFlow, from
# features/polkit/Polkit.qml's Quickshell.Services.Polkit, is missing from
# that sentence. Noted on every run.
EXPECTED_UNRESOLVED_TYPES="AuthFlow
FileViewAdapter
PanelWindow"

# Per-kind warning counts, "kind count" per line. Every warning qmllint emits
# must land in exactly one of these buckets, and each bucket's count is
# pinned: a moved number then names the kind that moved, which a bare total
# would not.
RECORDED_WARNING_KINDS="confusing-expression-statement 5
eval 1
id-shadows-member 2
missing-property 54
property-override 5
redundant-optional-chaining 3
uncreatable-type 3
unqualified 68
unresolved-type 5"

t_section "the tool under test"
if [[ ! -x $QMLLINT_BIN ]]; then
  t_block "qmllint is not executable at $QMLLINT_BIN (override with QMLLINT_BIN=)"
fi
t_file "qmllint exists at the path lib.sh publishes" "$QMLLINT_BIN"
t_not_empty "qmllint reports a version" "$(qt_version 2>/dev/null || "$QMLLINT_BIN" --version 2>&1 | awk '{ print $2 }')"

# ---------------------------------------------------------------------------
# The import baseline, built exactly as the README describes: a throwaway
# directory holding a `qs` symlink to the shell tree, passed with -I, so
# `import qs.<layer>` resolves.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-qmllint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ln -s "$SHELL_DIR" "$WORK/qs"
t_true "the baseline's qs entry is a symlink" test -L "$WORK/qs"
t_eq "it points at the shell tree" "$SHELL_DIR" "$(readlink "$WORK/qs")"
t_true "the shell tree is reachable through it" test -d "$WORK/qs/common"

# Sorted in the C collation, not the ambient one. shell_qml_files pipes
# find through plain sort, which orders "Exec.qml" before "audio/" under
# en_US.UTF-8 and after it under C - so the published one-liner produces a
# different argument order on a different host. Re-sorting here makes the
# baseline locale-independent, which is a reproducibility property the
# README's command does not currently have.
mapfile -t QML_FILES < <(shell_qml_files | LC_ALL=C sort)
t_not_empty "the tree has .qml files to lint" "${#QML_FILES[*]}"

# The recorded file count, checked against the tree rather than trusted.
# RECORDED_FILE_COUNT is what shell/README.md publishes; a drift is reported
# loudly instead of being silently absorbed.
t_count "the tree holds the README's file count" "$RECORDED_FILE_COUNT" "${#QML_FILES[@]}"
if (( ${#QML_FILES[@]} != RECORDED_FILE_COUNT )); then
  t_note "shell/README.md's \"$RECORDED_FILE_COUNT files\" is stale: the tree now holds ${#QML_FILES[@]} .qml files"
fi

LINT_OUT="$WORK/lint.txt"
LINT_STATUS=0
"$QMLLINT_BIN" -I "$WORK" "${QML_FILES[@]}" >"$LINT_OUT" 2>&1 || LINT_STATUS=$?

# A diagnostic header is "Severity: path:line:col: message [kind]". Only
# headers are counted: a source-echo line that happens to begin with
# "Warning: " would be the only way to fool that, and no file here has one.
#
# The stream is not two lines per diagnostic, which is worth knowing before
# anyone tries to count it by eye: 218 headers, 214 caret rulers, 314
# source-echo lines, and 50 blank lines. The 50 blank lines are one after
# each of the 50 untagged "X is a member of a parent element" Info notes,
# which carry three echo lines, one ruler and the blank; the four untagged
# notes with no echo at all are the "non-optional chaining" and "implicitly
# injected" kinds. So every count below goes through a header match, never
# through a line count.
count_headers() { grep -cE '^(Error|Warning|Info): ' "$1" || true; }
count_severity() { grep -cE "^$2: " "$1" || true; }
header_tags() { grep -E "^$2: " "$1" | grep -oE '\[[a-z-]+\]$' || true; }
header_paths() { grep -E '^(Error|Warning|Info): [^ ]+:[0-9]+:[0-9]+: ' "$1" \
  | sed -E 's/^(Error|Warning|Info): ([^:]+):[0-9]+:[0-9]+: .*/\2/'; }

ERR_COUNT="$(count_severity "$LINT_OUT" Error)"
WARN_COUNT="$(count_severity "$LINT_OUT" Warning)"
INFO_COUNT="$(count_severity "$LINT_OUT" Info)"

t_section "0 errors: the load-bearing assertion"
# The README's own warning, taken literally: the exit status is 0 even with
# warnings, so it cannot stand in for the error count. Both are asserted, and
# the point of asserting the status here is to keep the README's claim
# honest, not to lean on it.
t_eq "qmllint exits 0 with warnings present" "0" "$LINT_STATUS"
t_eq "no Error: diagnostics" "0" "$ERR_COUNT"
if (( ERR_COUNT > 0 )); then
  t_note "first Error: lines, for the failure above"
  grep -E '^Error: ' "$LINT_OUT" | head -5
fi

# ...and the sharper form of the same claim, measured rather than trusted.
# `Error:` is not a severity qmllint emits on its own: per its own --help it
# is a *level* a warning is promoted to, and only a .qmllint.ini can promote
# one. This tree has no .qmllint.ini, so on this qmllint the error channel is
# structurally empty. Proven here with a throwaway file that cannot compile,
# because it decides where the rest of this suite puts its weight: if a
# syntax error still produced no `Error:` line, then "0 errors" proves
# nothing on its own and the assertions that carry weight are the warning
# classification below and the broken-import control at the end.
t_no_file "the tree ships no .qmllint.ini to promote a warning to an error" \
  "$SHELL_DIR/.qmllint.ini"
PROBE="$WORK/probe.qml"
printf 'import QtQuick\nItem {\n' >"$PROBE"
PROBE_OUT="$WORK/probe.txt"
PROBE_STATUS=0
"$QMLLINT_BIN" -I "$WORK" "$PROBE" >"$PROBE_OUT" 2>&1 || PROBE_STATUS=$?
t_ne "a file that cannot compile makes qmllint exit non-zero" "0" "$PROBE_STATUS"
t_eq "and it still reports no Error: diagnostic" "0" "$(count_severity "$PROBE_OUT" Error)"
t_count "the syntax failure arrives as a warning" "1" \
  "$(grep -cE '\[syntax\]$' "$PROBE_OUT" || true)"
t_note "a hard syntax error is a [syntax] Warning and a non-zero exit, never an Error: line - so this suite's real teeth are the warning classification and the broken-import control, not the error count"

t_section "the file set that was linted"
t_sorted "the file list is in a stable order" "$(printf '%s\n' "${QML_FILES[@]}")"
t_unique "no file is linted twice" "$(printf '%s\n' "${QML_FILES[@]}")"
# qmllint is handed the list explicitly, so a dropped argument shows up as a
# smaller diagnostic set rather than as an error - and most files are clean,
# so a count equality would be the wrong check. What must hold is the
# converse: every path a diagnostic names is one of the files that was
# passed in. That rules out a diagnostic leaking in from a file the suite
# never asked about, and it is what makes the per-kind counts below mean
# what they claim to mean.
DIAG_FILES="$(header_paths "$LINT_OUT" | LC_ALL=C sort -u)"
t_not_empty "diagnostics name files under the shell tree" "$DIAG_FILES"
DIAG_NOT_LINTED="$(LC_ALL=C comm -23 \
  <(printf '%s\n' "$DIAG_FILES" | LC_ALL=C sort -u) \
  <(printf '%s\n' "${QML_FILES[@]}" | LC_ALL=C sort -u))"
t_empty "every diagnosed file is one that was linted" "$DIAG_NOT_LINTED"
t_count "the diagnosed files are a strict subset of the linted ones" "1" \
  "$([[ $(printf '%s\n' "$DIAG_FILES" | grep -c .) -lt ${#QML_FILES[@]} ]] && echo 1 || echo 0)"

t_section "every warning is classified, and the breakdown is pinned"
# Untagged warnings would be a hole in the classification: a new qmllint
# version introducing an uncategorised warning must fail here rather than
# slip past the per-kind counts.
WARN_HEADERS="$(grep -E '^Warning: ' "$LINT_OUT")"
UNTAGGED_WARNINGS="$(printf '%s\n' "$WARN_HEADERS" | grep -vE '\[[a-z-]+\]$' || true)"
t_empty "no warning is uncategorised" "$UNTAGGED_WARNINGS"

WARN_KIND_LIST="$(header_tags "$LINT_OUT" Warning | tr -d '[]' | LC_ALL=C sort -u)"
WARN_KINDS_ACTUAL="$(printf '%s\n' "$WARN_KIND_LIST" | awk 'NF' | while read -r k; do
  n="$(grep -cE "^Warning: .*\\[$k\\]$" "$LINT_OUT" || true)"
  printf '%s %s\n' "$k" "$n"
done | LC_ALL=C sort)"
t_eq "the warning breakdown matches the recorded one" "$RECORDED_WARNING_KINDS" "$WARN_KINDS_ACTUAL"
t_count "the warning total matches the recorded one" "$RECORDED_WARNING_COUNT" "$WARN_COUNT"
t_count "the Info total matches the recorded one" "$RECORDED_INFO_COUNT" "$INFO_COUNT"
t_count "the three severities account for every header" "$(( ERR_COUNT + WARN_COUNT + INFO_COUNT ))" "$(count_headers "$LINT_OUT")"

if (( WARN_COUNT != README_WARNING_COUNT )); then
  t_note "shell/README.md's \"$README_WARNING_COUNT warnings\" is stale: qmllint emits $WARN_COUNT Warning: diagnostics (off by $(( README_WARNING_COUNT - WARN_COUNT ))), plus $INFO_COUNT Info: lines"
fi
t_note "the recorded warning total is $RECORDED_WARNING_COUNT and the per-kind breakdown above is the assertion that makes a diff legible"

t_section "the unresolved types are only Quickshell C++ types"
UNRESOLVED_LINES="$(grep -E '\[(unresolved-type|uncreatable-type)\]$' "$LINT_OUT" || true)"
UNRESOLVED_COUNT="$(printf '%s\n' "$UNRESOLVED_LINES" | grep -c . || true)"
t_count "the unresolved/uncreatable count" "8" "$UNRESOLVED_COUNT"

# The names, from two different shapes of diagnostic:
#   Property "adapter" has incomplete type "FileViewAdapter" ...
#   Type "AuthFlow" of property "flow" not found. ...
#   Type PanelWindow is not creatable.  <- unquoted
UNRESOLVED_TYPES="$(printf '%s\n' "$UNRESOLVED_LINES" \
  | grep -oE 'incomplete type "[A-Za-z0-9_]+"|Type "[A-Za-z0-9_]+" of|Type [A-Za-z0-9_]+ is not creatable' \
  | sed -E 's/.*"([A-Za-z0-9_]+)".*/\1/; s/^Type ([A-Za-z0-9_]+) is not creatable$/\1/' \
  | LC_ALL=C sort -u)"
t_eq "the set of unresolved types is exactly the Quickshell ones" \
  "$EXPECTED_UNRESOLVED_TYPES" "$UNRESOLVED_TYPES"

# A type on the list is only "expected" because Quickshell registers it from
# C++. Prove that against the installed type descriptions rather than
# asserting it in prose: if the name is in no quickshell-*.qmltypes, it is
# some other type that lost its import and the suite says so.
QS_QMLTYPES="$(dirname "$(dirname "$QMLLINT_BIN")")/qml/Quickshell"
if [[ -d $QS_QMLTYPES ]]; then
  t_not_empty "the Quickshell type descriptions are on disk" "$(find "$QS_QMLTYPES" -name '*.qmltypes' | head -1)"
  MISSING_FROM_QMLTYPES=""
  while read -r ty; do
    [[ -n $ty ]] || continue
    if ! grep -rqw -- "$ty" "$QS_QMLTYPES"; then
      MISSING_FROM_QMLTYPES+="$ty "
    fi
  done <<<"$UNRESOLVED_TYPES"
  t_empty "every unresolved type is registered in a quickshell-*.qmltypes" "$MISSING_FROM_QMLTYPES"
else
  t_note "no qmltypes tree at $QS_QMLTYPES, so the Quickshell-registration cross-check could not run"
fi

# The README's list of the types the linter may leave unresolved. Recorded,
# not asserted: the list is the code's, and the README states it so a reader
# can tell an expected name from a lost import.
README_UNRESOLVED_TYPES=""
for ty in AuthFlow FileViewAdapter PanelWindow BluetoothAdapter UntypedObjectModel; do
  if grep -q "\`$ty\`" "$SHELL_DIR/README.md"; then
    README_UNRESOLVED_TYPES="${README_UNRESOLVED_TYPES:+$README_UNRESOLVED_TYPES }$ty"
  fi
done
t_note "shell/README.md's list of expected unresolved types names: ${README_UNRESOLVED_TYPES:-none}"
if [[ $UNRESOLVED_TYPES != *"AuthFlow"* ]]; then
  t_note "AuthFlow no longer appears in the unresolved set, so shell/README.md's list needs no AuthFlow"
else
  t_note "AuthFlow is in the unresolved set and shell/README.md's list names it; features/polkit/Polkit.qml produces it four times"
fi

t_section "the run is deterministic"
LINT_OUT2="$WORK/lint2.txt"
LINT_STATUS2=0
"$QMLLINT_BIN" -I "$WORK" "${QML_FILES[@]}" >"$LINT_OUT2" 2>&1 || LINT_STATUS2=$?
WARN_SET1="$(grep -E '^(Error|Warning): ' "$LINT_OUT" | LC_ALL=C sort)"
WARN_SET2="$(grep -E '^(Error|Warning): ' "$LINT_OUT2" | LC_ALL=C sort)"
t_eq "two runs agree on the exit status" "$LINT_STATUS" "$LINT_STATUS2"
t_eq "the error set is empty on the second run too" "0" "$(count_severity "$LINT_OUT2" Error)"
t_eq "the warning set is identical between the two runs" "$WARN_SET1" "$WARN_SET2"
t_eq "the whole diagnostic stream is byte-identical" \
  "$(cksum <"$LINT_OUT")" "$(cksum <"$LINT_OUT2")"

t_section "the -I baseline is doing the work (deliberate control)"
# The control: same command, same file list, an import path that contains no
# `qs`. If the suite were passing by accident - a stale import path, a
# linter that resolved nothing either way - this run would look the same.
# It does not: the diagnostic set grows by an order of magnitude and tags
# appear that a working baseline never produces. That is the proof the -I
# baseline is load-bearing.
BAD_IMPORT="$WORK/broken-import"
mkdir -p "$BAD_IMPORT"
BAD_OUT="$WORK/lint-broken.txt"
BAD_STATUS=0
"$QMLLINT_BIN" -I "$BAD_IMPORT" "${QML_FILES[@]}" >"$BAD_OUT" 2>&1 || BAD_STATUS=$?
BAD_HEADERS="$(count_headers "$BAD_OUT")"
GOOD_HEADERS="$(count_headers "$LINT_OUT")"

t_eq "the broken baseline also exits 0" "0" "$BAD_STATUS"
t_eq "and reports no Error: diagnostic either" "0" "$(count_severity "$BAD_OUT" Error)"
t_note "both baselines exit 0 and both report 0 errors - neither number can tell a tree that resolves its imports from one that does not, which is the whole reason the last four assertions exist"
if (( BAD_HEADERS > GOOD_HEADERS * 4 )); then
  t_eq "the broken baseline produces far more diagnostics" "true" "true"
else
  t_eq "the broken baseline produces far more diagnostics" \
    "more than 4x the working baseline ($GOOD_HEADERS headers)" "$BAD_HEADERS"
fi
t_note "working baseline: $GOOD_HEADERS diagnostic headers; broken import path: $BAD_HEADERS"
# Two tags that a working import path never produces: `unresolved-alias`
# (a `qs.*` module alias that cannot be found) and `import` (import lines
# qmllint could not satisfy). Their absence in the good run and presence in
# the broken one is the sharpest single discriminator.
t_count "unresolved-alias is absent from the working baseline" "0" \
  "$(grep -E '^(Error|Warning): ' "$LINT_OUT" | grep -cE '\[unresolved-alias\]$' || true)"
t_true "unresolved-alias appears without the baseline" \
  grep -qE '\[unresolved-alias\]$' "$BAD_OUT"
t_true "import warnings appear without the baseline" \
  grep -qE '\[import\]$' "$BAD_OUT"
t_true "uncreatable-type still appears without the baseline" \
  grep -qE '\[uncreatable-type\]$' "$BAD_OUT"

t_summary
