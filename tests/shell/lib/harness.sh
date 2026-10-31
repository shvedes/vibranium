#!/bin/bash
# Assertion harness for the shell test suites.
#
# Contract every suite follows:
#
#   source lib/harness.sh
#   t_init "suite-name"          # or: t_init "name" "description"
#   t_section "group"
#   t_eq "label" expected actual
#   t_summary
#
# t_summary is what decides the suite's exit status:
#
#   0   every assertion passed
#   1   at least one assertion failed
#   77  BLOCKED - the suite could not run here (missing tool, failed
#       platform gate). Never used to report a failure.
#
# The runner in run-all.sh reads the machine-readable result file to tell a
# genuine regression from a recorded pre-existing failure, so suites must
# only ever reach assertions through the t_* functions.

# Result file, set by run-all.sh. Format is TSV: status, section, label,
# detail. A suite that runs standalone gets a private file, and owns removing
# it: the runner sets SHELL_TEST_RESULTS so it can read the file after the
# suite exits, and a suite that deleted it would take the runner's copy with
# it. A standalone suite that leaks one file per run is a slow way to fill
# /tmp, so the private case is cleaned up on exit.
if [[ -n ${SHELL_TEST_RESULTS:-} ]]; then
  _T_RESULTS="$SHELL_TEST_RESULTS"
  _T_OWNS_RESULTS=0
else
  _T_RESULTS="$(mktemp "${TMPDIR:-/tmp}/vb-shell-results.XXXXXX")"
  export SHELL_TEST_RESULTS="$_T_RESULTS"
  _T_OWNS_RESULTS=1
  # shellcheck disable=SC2064  # the trap must expand now, not at fire time
  trap "rm -f '$_T_RESULTS'" EXIT
fi

T_NAME="unnamed"
T_DESC=""
T_PASS=0
T_FAIL=0
T_TOTAL=0
T_SECTION=""
_T_INIT_DONE=0

# Colour, dropped when stdout is not a terminal so CI logs stay readable.
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  _C_G=$'\e[0;32m'; _C_R=$'\e[0;31m'; _C_C=$'\e[0;36m'
  _C_Y=$'\e[0;33m'; _C_Z=$'\e[0;90m'; _C_B=$'\e[1m'; _C_0=$'\e[0m'
else
  _C_G=""; _C_R=""; _C_C=""; _C_Y=""; _C_Z=""; _C_B=""; _C_0=""
fi

# t_init <name> [description]
t_init() {
  T_NAME="$1"
  T_DESC="${2:-}"
  _T_INIT_DONE=1
  printf '%s%s%s' "$_C_B" "$T_NAME" "$_C_0"
  if [[ -n $T_DESC ]]; then
    printf ' %s- %s%s' "$_C_Z" "$T_DESC" "$_C_0"
  fi
  printf '\n'
}

t_section() {
  T_SECTION="$1"
  printf '\n%s--- %s ---%s\n' "$_C_C" "$1" "$_C_0"
}

_t_record() {
  local status="$1" label="$2" detail="${3:-}"
  # The detail is free text and routinely spans two lines ("expect: ...
  # got: ..."). Written raw, that second line becomes a second TSV row with
  # one field, and a detail line could even forge a PASS row for
  # run-all.sh's classifier. Escape the two characters the format cannot
  # carry, so one assertion is always exactly one row.
  detail="${detail//$'\n'/\\n}"
  detail="${detail//$'\t'/\\t}"
  printf '%s\t%s\t%s\t%s\n' "$status" "$T_SECTION" "$label" "$detail" >>"$_T_RESULTS"
}

_t_ok() {
  T_PASS=$((T_PASS + 1))
  T_TOTAL=$((T_TOTAL + 1))
  _t_record PASS "$1" "${2:-}"
  printf '  %s[%02d]%s %sPASS%s %s\n' "$_C_Z" "$T_TOTAL" "$_C_0" "$_C_G" "$_C_0" "$1"
}

_t_no() {
  local label="$1" detail="${2:-}"
  T_FAIL=$((T_FAIL + 1))
  T_TOTAL=$((T_TOTAL + 1))
  _t_record FAIL "$label" "$detail"
  printf '  %s[%02d]%s %sFAIL%s %s\n' "$_C_Z" "$T_TOTAL" "$_C_0" "$_C_R" "$_C_0" "$label"
  if [[ -n $detail ]]; then
    local _shown=0
    while IFS= read -r line; do
      if ((_shown >= 20)); then
        printf '        %s... (%d more lines omitted)%s\n' "$_C_Z" "$(( $(printf '%s\\n' "$detail" | wc -l) - _shown ))" "$_C_0"
        break
      fi
      printf '        %s%s%s\n' "$_C_Z" "$line" "$_C_0"
      _shown=$((_shown + 1))
    done <<<"$detail"
  fi
}

# t_skip <label> [reason] - records an explicitly unverified behaviour. Kept
# separate from t_block so the runner can count real coverage gaps. A skip is
# never a pass.
t_skip() {
  printf '  %s[%02d]%s %sSKIP%s %s %s(%s)%s\n' \
    "$_C_Z" "$((T_TOTAL + 1))" "$_C_0" "$_C_Y" "$_C_0" "$1" "$_C_Z" "${2:-no reason given}" "$_C_0"
  _t_record SKIP "$1" "${2:-}"
  T_TOTAL=$((T_TOTAL + 1))
}

# t_note <text> - a recorded observation that is not an assertion. Used for
# something the suite checked and that a reader should know about - a
# documented difference from the shell README, a value that depends on the
# host. Notes are counted separately from the pass/fail total so they can
# never be mistaken for coverage.
T_NOTES=0
t_note() {
  T_NOTES=$((T_NOTES + 1))
  printf '  %snote%s %s\n' "$_C_Y" "$_C_0" "$1"
  _t_record NOTE "$1"
}

# t_block <reason> - the whole suite cannot run. Prints the reason and exits
# with the BLOCKED status so the runner classifies it as unrunnable rather
# than failed.
t_block() {
  printf '\n%sBLOCKED%s %s\n' "$_C_Y" "$_C_0" "$1"
  _t_record BLOCKED "$T_NAME" "$1"
  exit 77
}

# t_ok <label> [detail] - record an unconditional pass. For work already done
# where what is being asserted is that it did not throw.
#
# t_no <label> [detail] - record an unconditional failure. The mirror of t_ok,
# and the primitive every other helper is built from: t_eq and friends are all
# "t_no unless the condition held". A suite asserting a failure it already
# observed uses this.
t_ok() {
  _t_ok "$1" "${2:-}"
}

t_no() {
  _t_no "$1" "${2:-}"
}

# t_eq <label> <expected> <actual>
t_eq() {
  if [[ "$2" == "$3" ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'expect: %s\ngot:    %s' "$2" "$3")"
  fi
}

# t_ne <label> <unexpected> <actual>
t_ne() {
  if [[ "$2" != "$3" ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'must not be: %s' "$2")"
  fi
}

# t_contains <label> <needle> <haystack>
t_contains() {
  if [[ "$3" == *"$2"* ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'must contain: %s\ngot:           %s' "$2" "$3")"
  fi
}

# t_not_contains <label> <needle> <haystack>
t_not_contains() {
  if [[ "$3" != *"$2"* ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'must not contain: %s\ngot:              %s' "$2" "$3")"
  fi
}

# t_match <label> <extended-regex> <actual> - regex match.
t_match() {
  if [[ "$3" =~ $2 ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'must match: %s\ngot:        %s' "$2" "$3")"
  fi
}

# t_not_match <label> <extended-regex> <actual>
t_not_match() {
  if [[ ! "$3" =~ $2 ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'must not match: %s\ngot:            %s' "$2" "$3")"
  fi
}

# t_true <label> <command...> - passes when the command exits 0.
t_true() {
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if ((rc == 0)); then
    _t_ok "$label"
  else
    _t_no "$label" "$(printf 'command: %s\nexit:    %d\noutput:  %s' "$*" "$rc" "$out")"
  fi
}

# t_false <label> <command...> - passes when the command exits non-zero.
t_false() {
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if ((rc != 0)); then
    _t_ok "$label"
  else
    _t_no "$label" "$(printf 'command: %s\nexit:    0 (expected non-zero)\noutput:  %s' "$*" "$out")"
  fi
}

# t_status <label> <expected-exit> <command...>
t_status() {
  local label="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if ((rc == want)); then
    _t_ok "$label"
  else
    _t_no "$label" "$(printf 'command: %s\nexpect exit: %d\ngot exit:    %d\noutput:  %s' "$*" "$want" "$rc" "$out")"
  fi
}

# t_empty <label> <value>
t_empty() {
  if [[ -z "$2" ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'must be empty, got: %s' "$2")"
  fi
}

# t_not_empty <label> <value>
t_not_empty() {
  if [[ -n "$2" ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "must not be empty"
  fi
}

# t_file <label> <path> - file exists and is readable.
t_file() {
  if [[ -f "$2" && -r "$2" ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'not a readable file: %s' "$2")"
  fi
}

# t_no_file <label> <path>
t_no_file() {
  if [[ ! -e "$2" ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'must not exist: %s' "$2")"
  fi
}

# t_lines <label> <expected-count> <actual>
t_lines() {
  if [[ "$2" == "$3" ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'expect %s line(s), got %s\nactual:\n%s' "$2" "$3" "$4")"
  fi
}

# t_sorted <label> <text> - the newline-separated text must already be in
# order. Used by the architecture suites, where a stable order is the
# property under test rather than a formatting detail.
t_sorted() {
  local label="$1" text="$2"
  local sorted
  sorted="$(printf '%s\n' "$text" | LC_ALL=C sort)"
  if [[ "$text" == "$sorted" ]]; then
    _t_ok "$label"
  else
    _t_no "$label" "$(printf 'expect (sorted):\n%s\nactual:\n%s' "$sorted" "$text")"
  fi
}

# t_unique <label> <text> - no duplicate lines.
t_unique() {
  local label="$1" text="$2"
  local total uniq_count
  total="$(printf '%s\n' "$text" | LC_ALL=C sort | wc -l)"
  uniq_count="$(printf '%s\n' "$text" | LC_ALL=C sort -u | wc -l)"
  if [[ "$total" == "$uniq_count" ]]; then
    _t_ok "$label"
  else
    _t_no "$label" "$(printf 'duplicate lines in:\n%s' "$text")"
  fi
}

# t_count <label> <expected-count> <actual> - numeric equality where the
# values may be non-numeric strings such as "12 " or "+3".
t_count() {
  if [[ "$2" == "$3" ]]; then
    _t_ok "$1"
  else
    _t_no "$1" "$(printf 'expect count: %s, got: %s' "$2" "$3")"
  fi
}

t_summary() {
  local width=62
  printf '\n%s\n' "$(printf '=%.0s' $(seq 1 $width))"
  if ((T_FAIL == 0)); then
    printf '  %s%s passed%s' "$_C_G" "$T_PASS" "$_C_0"
  else
    printf '  %s%s passed%s  %s%s failed%s  %d total' \
      "$_C_G" "$T_PASS" "$_C_0" "$_C_R" "$T_FAIL" "$_C_0" "$T_TOTAL"
  fi
  if ((T_NOTES > 0)); then
    printf '  %s%d note%s%s' "$_C_Y" "$T_NOTES" "$_C_0" "$_C_0"
  fi
  printf '  %s(%s)%s\n' "$_C_Z" "$T_NAME" "$_C_0"
  printf '%s\n\n' "$(printf '=%.0s' $(seq 1 $width))"
  ((T_FAIL == 0))
}
