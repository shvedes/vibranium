#!/bin/bash
# The shell test suite runner.
#
#   bash tests/shell/run-all.sh                 run everything, classified
#   bash tests/shell/run-all.sh --list          the suites and what they cover
#   bash tests/shell/run-all.sh --only menu     run matching suites
#   bash tests/shell/run-all.sh --only js -v    run a group, full output
#   bash tests/shell/run-all.sh --baseline      the recorded pre-existing
#                                              failures, with provenance
#
# Classification, per suite:
#
#   PASS        every assertion passed
#   BASELINE    red by exactly the recorded pre-existing failures in
#               baseline.txt - a claim that must stay true, not a waiver
#   BLOCKED     could not run here (missing tool, failed platform gate).
#               Never counted as a pass.
#   REGRESSION  any failure outside the baseline. The runner exits 1.
#
# A BASELINE suite that goes green is reported as RESOLVED, because a stale
# baseline entry is a claim about a defect that no longer exists and should
# be pruned rather than left to rot.
#
# Every suite is run sequentially and in a fixed order. The whole thing takes
# about half a minute; trading that for a run whose output does not depend on
# scheduling is the right way round.

set -uo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RUNNER_DIR/lib/lib.sh"

BASELINE_FILE="$RUNNER_DIR/baseline.txt"

# --- presentation ----------------------------------------------------------

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_PASS=$'\e[0;32m'; C_BASE=$'\e[0;33m'; C_BLOC=$'\e[0;36m'
  C_REG=$'\e[0;31m'; C_DIM=$'\e[0;90m'; C_BOLD=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_PASS=""; C_BASE=""; C_BLOC=""; C_REG=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi

VERBOSE=0
QUIET=0
JOBS="$(nproc)"
ONLY=""
WANT_BASELINE=0
WANT_LIST=0

usage() {
  cat <<EOF
Usage: run-all.sh [options]

  --only <pattern>   run only the suites whose name matches <pattern>.
                     A plain substring match, and comma-separated for
                     several: 'menu,unitgate' runs both.
  -v, --verbose      show each suite's own output, not just its summary
  --quiet            suppress the per-suite progress lines on stderr
  --jobs <n>         run up to n suites at once (default: nproc). The report is
                     identical either way: it is built from what each suite
                     recorded, in discovery order, not in completion order.
                     4 is about 3x faster on this tree. Watch the memory -
                     the JS suites each hold a loaded library set.
  --baseline         print the recorded pre-existing failures, with the
                     reason each was recorded, then exit
  --list             list the suites and what each one covers
  -h, --help         this text
EOF
}

while (($#)); do
  case "$1" in
  --only) ONLY="${2:-}"; shift 2 ;;
  --only=*) ONLY="${1#*=}"; shift ;;
  -v | --verbose) VERBOSE=1; shift ;;
  --quiet) QUIET=1; shift ;;
  --jobs) JOBS="${2:-1}"; shift 2 ;;
  --jobs=*) JOBS="${1#*=}"; shift ;;
  --baseline) WANT_BASELINE=1; shift ;;
  --list) WANT_LIST=1; shift ;;
  -h | --help) usage; exit 0 ;;
  *)
    printf 'unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

if [[ ! $JOBS =~ ^[1-9][0-9]*$ ]]; then
  printf -- '--jobs wants a positive integer, got "%s"\n' "$JOBS" >&2
  exit 2
fi

# --- suite discovery -------------------------------------------------------
#
# A suite is any *.sh under suites/ or any *.test.mjs under suites/. The
# directory decides the layer it belongs to, which is what makes the --list
# output a map of the tree rather than a flat list.

declare -a SUITE_PATH SUITE_NAME SUITE_KIND SUITE_GROUP

discover() {
  local path name kind group under
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    name="$(basename "$path")"
    # Only the two suite spellings are discovered. A bare *.sh match would
    # sweep up a scratch or debugging script dropped in the same directory and
    # report it as a test suite that passed.
    case "$name" in
    *.test.mjs) name="${name%.test.mjs}"; kind=node ;;
    *-test.sh) name="${name%-test.sh}"; kind=bash ;;
    *) continue ;;
    esac
    # The -test suffix is a filename convention, not part of the suite's
    # identity: --only, the baseline file and the report all use the short
    # name so `run-all.sh --only menu` works.
    name="${name%-test}"
    under="${path#"$RUNNER_DIR/suites/"}"
    group="$(dirname "$under")"
    group="${group//\//.}"
    [[ $group == "." ]] && group=root
    SUITE_PATH+=("$path")
    SUITE_NAME+=("$name")
    SUITE_KIND+=("$kind")
    SUITE_GROUP+=("$group")
  done < <(
    {
      find "$RUNNER_DIR/suites" -type f -name '*.sh' 2>/dev/null
      find "$RUNNER_DIR/suites" -type f -name '*.test.mjs' 2>/dev/null
    } | LC_ALL=C sort
  )
}

discover

# --- what each suite covers ------------------------------------------------

describe() {
  case "$1" in
  layers) printf 'the four-layer import contract and every resolved edge' ;;
  imports) printf 'every import in the tree resolves to something real' ;;
  qmldir) printf 'module declarations, entry grammar, aliased member reads' ;;
  unitgate) printf 'the boot lifecycle state machine, in a live Quickshell' ;;
  boot-catalog) printf 'the 47-unit boot catalog against UnitGate rules' ;;
  
  ipptool) printf 'the nine IPP request templates and the parser that reads them' ;;
  qmllint) printf 'the reproducible lint baseline and its warning breakdown' ;;
  assets) printf 'every shipped icon is reachable, and every reference resolves' ;;
  hyprland-editor-cli) printf 'the node CLI over the Hyprland config editor' ;;
  text) printf 'StringUtils, EditUtils, ImageExts' ;;
  collections) printf 'BoundedCache, FrozenFootprint, ZoneGeometry' ;;
  mixer-model) printf 'MixerModel: node classification, labels, levels, the pactl parser' ;;
  window-match) printf 'WindowMatch: notification sender identity to window, three match phases' ;;
  math-calc-color) printf 'FuncLib, CalcLib, ColorMath, ColorLib, UnitLib' ;;
  path-process-runtime) printf 'PathPolicy, CommandSpec' ;;
  settings) printf 'SettingsLib, HyprlandEditor' ;;
  launcher) printf 'LauncherLib, PluginPolicy, TimeLib, and plugin/lib parity' ;;
  clipboard) printf 'ClipboardLib' ;;
  menu) printf 'MenuLib' ;;
  capture-annotations) printf 'RectMath, ShotLib, AnnotationTools' ;;
  bar-models) printf 'BarLib, the bar module models, and the media helpers' ;;
  services-calendar-weather) printf 'CalendarLib, PrivacyLib, PrintersLib, weather Model' ;;
  registry-bus) printf 'the service locator and the one-way notification bus' ;;
  
  paths-presence) printf 'path derivation invariants and refcounted file presence' ;;
  ui) printf 'common/ui: layout, derived state, signals and animation, event-loop driven' ;;
  ui-rest) printf 'the rest of common/ui: Icon, GridList, ScrollBar, DropdownSlot, panels' ;;
  list) printf 'List.qml: selection, keyboard navigation and the scroll model' ;;
  list-instantiation) printf 'List.qml: what the cacheBuffer policy actually instantiates' ;;
  textinput) printf 'InputField and PasswordBox: masking, reveal, signals, focus' ;;
  host-button) printf 'IslandHost open state and frozen footprints; IconButton interaction' ;;
  calendar-graph) printf 'Calendar month grid and FunctionGraph sampling and axis maths' ;;
  construction) printf 'every declared QML type constructs, bucketed by why not' ;;
  harness) printf 'the assertion kit itself fails when it should' ;;
  modules-wallpaper) printf 'the last pure-JS files: bar module models and WallpaperTrans' ;;
  settings-catalog) printf 'the 32 settings catalog files, run through the real engine' ;;
  themes) printf 'the 30 shipped themes and the palette the shell reads' ;;
  *) printf '' ;;
  esac
}

if ((WANT_LIST)); then
  printf '%sshell test suites%s  %s(%d)%s\n' "$C_BOLD" "$C_OFF" "$C_DIM" "${#SUITE_NAME[@]}" "$C_OFF"
  group_last=""
  for i in "${!SUITE_NAME[@]}"; do
    if [[ ${SUITE_GROUP[$i]} != "$group_last" ]]; then
      group_last="${SUITE_GROUP[$i]}"
      printf '\n%s%s%s\n' "$C_BOLD" "$group_last" "$C_OFF"
    fi
    printf '  %-24s %s\n' "${SUITE_NAME[$i]}" "$(describe "${SUITE_NAME[$i]}")"
  done
  printf '\n'
  exit 0
fi

# --- the recorded baseline -------------------------------------------------
#
# Format, one record per line:
#
#   <suite><TAB><assertion label><TAB><reason it was recorded>
#
# The reason is not decoration: a baseline entry without one is indistinguishable
# from a test nobody got around to writing, and it is the difference between a
# known defect and a forgotten promise.

declare -A BASELINE_REASON
BASELINE_COUNT=0

load_baseline() {
  [[ -f $BASELINE_FILE ]] || return 0
  local suite label reason
  while IFS=$'\t' read -r suite label reason; do
    [[ -n $suite && -n $label ]] || continue
    [[ $suite == \#* ]] && continue
    BASELINE_REASON["$suite"$'\t'"$label"]="$reason"
    BASELINE_COUNT=$((BASELINE_COUNT + 1))
  done <"$BASELINE_FILE"
}

load_baseline

if ((WANT_BASELINE)); then
  if ((BASELINE_COUNT == 0)); then
    printf '%sNo baseline recorded.%s\n' "$C_DIM" "$C_OFF"
    printf 'Every suite is expected to be green; there is no known-red to waive.\n\n'
    exit 0
  fi
  printf '%sRecorded pre-existing failures%s  %s(%d across the suite)%s\n\n' \
    "$C_BOLD" "$C_OFF" "$C_DIM" "$BASELINE_COUNT" "$C_OFF"
  # Sorted by suite then label: the report is read by people comparing two
  # runs, and an unordered listing makes that comparison a chore.
  for i in "${!SUITE_NAME[@]}"; do
    local_name="${SUITE_NAME[$i]}"
    printed=0
    while IFS= read -r key; do
      [[ -n $key ]] || continue
      ((printed)) || { printf '%s%s%s\n' "$C_BOLD" "$local_name" "$C_OFF"; printed=1; }
      printf '  %s\n      %s\n' "${key#*$'\t'}" "${BASELINE_REASON[$key]}"
    done < <(
      for k in "${!BASELINE_REASON[@]}"; do
        [[ $k == "$local_name"$'\t'* ]] && printf '%s\n' "$k"
      done | LC_ALL=C sort -t $'\t' -k2
    )
  done
  printf '\n%sA baseline is a claim that must stay true. If a suite goes red\n' "$C_DIM"
  printf 'beyond these, the runner reports it as a REGRESSION and exits 1.%s\n\n' "$C_OFF"
  exit 0
fi

# --- run -------------------------------------------------------------------

declare -a RESULTS
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
TOTAL_NOTE=0
N_PASS=0
N_BASELINE=0
N_BLOCKED=0
N_REGRESSION=0
N_RESOLVED=0
N_SKIPPED=0
N_EMPTY=0

WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-run.XXXXXX")"
cleanup() { rm -rf "$WORKROOT"; }
trap cleanup EXIT

# Every suite runs before the final table is printed, so the report below can
# measure its column widths from the data rather than guess them. That makes
# the run silent by default, which reads as a hang - so a progress line goes to
# STDERR as each suite finishes. stdout stays the clean report, so
# `run-all.sh > report.txt` gives an aligned table with no interleaving.
RUN_START=$(date +%s)
# _tick hands out a completion number that is safe to call from a background
# subshell, which a plain variable increment is not: the increment happens in
# the subshell and is discarded, so every line would read 1. mkdir is atomic on
# every filesystem this runs on, which makes it a lock without needing flock.
CTR_DIR="$WORKROOT/.ctr"
CTR_FILE="$WORKROOT/.ctr.n"
printf '0' >"$CTR_FILE"

_tick() {
  local n
  while ! mkdir "$CTR_DIR" 2>/dev/null; do sleep 0.005; done
  n="$(cat "$CTR_FILE" 2>/dev/null || echo 0)"
  printf '%s' "$((n + 1))" >"$CTR_FILE"
  rmdir "$CTR_DIR" 2>/dev/null
  printf '%s' "$((n + 1))"
}

_progress() {
  ((QUIET)) && return 0
  local done="$1" total="$2" name="$3" status="$4" ms="$5"
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - RUN_START))
  local colour=""
  case "$status" in
  PASS) colour="$C_PASS" ;;
  REGRESSION | EMPTY) colour="$C_REG" ;;
  BLOCKED) colour="$C_BLOC" ;;
  *) colour="$C_BASE" ;;
  esac
  # A suite past this is worth naming as slow, because otherwise a 20s qmllint
  # looks identical to a hang.
  local slow=""
  ((ms >= 3000)) && slow=" ${C_DIM}(slow)${C_OFF}"
  printf '%s[%2d/%2d]%s %s%-10s%s %-24s %6dms  %selapsed %ds%s%s\n' \
    "$C_DIM" "$done" "$total" "$C_OFF" \
    "$colour" "$status" "$C_OFF" "$name" "$ms" \
    "$C_DIM" "$elapsed" "$C_OFF" "$slow" >&2
}

# Resolve --only into an explicit index list, before the run.
#
# An exact suite name wins over a substring: `--only ui` should mean the `ui`
# suite, not also `ui-rest` and `ui-rest`'s neighbours, which is both surprising
# and easy to misread. Only if nothing matches exactly does it fall back to
# substring matching, so `--only js` still picks up a group.
declare -a SELECTED=()
if [[ -n $ONLY ]]; then
  IFS=',' read -ra _patterns <<<"$ONLY"
  declare -a _exact=()
  declare -a _substr=()
  for p in "${_patterns[@]}"; do
    [[ -z $p ]] && continue
    found_exact=0
    for i in "${!SUITE_NAME[@]}"; do
      if [[ ${SUITE_NAME[$i]} == "$p" ]]; then
        _exact+=("$i")
        found_exact=1
      fi
    done
    if ((found_exact == 0)); then
      for i in "${!SUITE_NAME[@]}"; do
        [[ ${SUITE_NAME[$i]} == *"$p"* ]] && _substr+=("$i")
      done
    fi
  done
  if ((${#_exact[@]} > 0)); then
    SELECTED=("${_exact[@]}")
  else
    SELECTED=("${_substr[@]}")
  fi
  # De-duplicate: two patterns can both match the same suite.
  if ((${#SELECTED[@]} > 0)); then
    declare -a _uniq=()
    declare -A _seen=()
    for i in "${SELECTED[@]}"; do
      [[ -n ${_seen[$i]:-} ]] && continue
      _seen[$i]=1
      _uniq+=("$i")
    done
    SELECTED=("${_uniq[@]}")
  fi
fi
RUN_TOTAL="${#SELECTED[@]}"
((RUN_TOTAL == 0)) && RUN_TOTAL="${#SUITE_NAME[@]}"

if ((!QUIET)); then
  {
    printf '%sshell test suite%s  %s(%d discovered' "$C_BOLD" "$C_OFF" "$C_DIM" "${#SUITE_NAME[@]}"
    if [[ -n $ONLY ]]; then
      printf ', %d selected by --only %s' "$RUN_TOTAL" "$ONLY"
    fi
    printf ')%s\n' "$C_OFF"
    printf '%sprogress goes to stderr; the report goes to stdout.%s\n\n' "$C_DIM" "$C_OFF"
  } >&2
fi


# ---- phase 1: execute ----------------------------------------------------
#
# Execution is separated from reporting so it can be parallel without making
# the report order-dependent. Each suite writes its own log, results and exit
# code; the classification below then walks the suites in DISCOVERY order, so
# the table is byte-identical whatever order they finish in.
#
# A suite running under offscreen Quickshell or qmllint is memory-hungry, so
# --jobs is opt-in and the default stays 1.

_run_one() {
  local name="$1" path="$2" kind="$3"
  local results="$WORKROOT/$name.results"
  local log="$WORKROOT/$name.log"
  local rc_file="$WORKROOT/$name.rc"
  local t0 t1 rc_status
  : >"$results"
  t0=$(date +%s%N)
  if [[ $kind == node ]]; then
    SHELL_TEST_RESULTS="$results" node "$path" >"$log" 2>&1
  else
    SHELL_TEST_RESULTS="$results" bash "$path" >"$log" 2>&1
  fi
  rc_status=$?
  printf '%s' "$rc_status" >"$rc_file"
  t1=$(date +%s%N)
  local ms=$(((t1 - t0) / 1000000))
  printf '%s' "$ms" >"$WORKROOT/$name.ms"

  # Announce here, not in the reporting phase: under --jobs the whole point is
  # to see a line the moment a suite lands, and a report-phase line would
  # appear all at once after everything had already finished.
  local st="PASS"
  if [[ $rc_status == 77 ]]; then
    st="BLOCKED"
  elif grep -q '^FAIL' "$results" 2>/dev/null; then
    st="REGRESSION"
  fi
  _progress "$(_tick)" "$RUN_TOTAL" "$name" "$st" "$ms"
}

if ((JOBS > 1)); then
  running=0
  for i in "${!SUITE_NAME[@]}"; do
    if ((${#SELECTED[@]} > 0)) && [[ " ${SELECTED[*]} " != *" $i "* ]]; then
      continue
    fi
    _run_one "${SUITE_NAME[$i]}" "${SUITE_PATH[$i]}" "${SUITE_KIND[$i]}" &
    running=$((running + 1))
    if ((running >= JOBS)); then
      wait -n 2>/dev/null || true
      running=$((running - 1))
    fi
  done
  # The progress lines, in discovery order rather than completion order, so
  # the counters read 1..N rather than racing.
  wait
fi

# ---- phase 2: classify and report ----------------------------------------
RUN_DONE=0
for i in "${!SUITE_NAME[@]}"; do
  name="${SUITE_NAME[$i]}"
  status_override=""

  if ((${#SELECTED[@]} > 0)) && [[ " ${SELECTED[*]} " != *" $i "* ]]; then
    N_SKIPPED=$((N_SKIPPED + 1))
    continue
  fi

  results="$WORKROOT/$name.results"
  rc="$(cat "$WORKROOT/$name.rc" 2>/dev/null || echo 1)"
  ms="$(cat "$WORKROOT/$name.ms" 2>/dev/null || echo 0)"

  if ((JOBS <= 1)); then
    _run_one "$name" "${SUITE_PATH[$i]}" "${SUITE_KIND[$i]}"
    rc="$(cat "$WORKROOT/$name.rc")"
    ms="$(cat "$WORKROOT/$name.ms")"
  fi

  # The results file is the authoritative record; the exit status is the
  # fallback for a suite that died before it could write one.
  n_pass=$(awk -F'\t' '$1 == "PASS"' "$results" 2>/dev/null | wc -l | tr -d ' ')
  n_fail=$(awk -F'\t' '$1 == "FAIL"' "$results" 2>/dev/null | wc -l | tr -d ' ')
  n_skip=$(awk -F'\t' '$1 == "SKIP"' "$results" 2>/dev/null | wc -l | tr -d ' ')
  n_note=$(awk -F'\t' '$1 == "NOTE"' "$results" 2>/dev/null | wc -l | tr -d ' ')

  if ((n_pass + n_fail + n_skip == 0)); then
    # A suite that recorded no assertions at all has not demonstrated
    # anything, whatever its exit status. Reporting it as a pass is the exact
    # failure this guards: a suite that cannot fail, going green forever.
    if ((rc == 0)); then
      status_override="EMPTY"
    else
      # It failed to start. Counting a synthetic failure points at the real
      # cause rather than reporting an empty-but-green suite.
      n_fail=1
    fi
  fi

  TOTAL_PASS=$((TOTAL_PASS + n_pass))
  TOTAL_FAIL=$((TOTAL_FAIL + n_fail))
  TOTAL_SKIP=$((TOTAL_SKIP + n_skip))
  TOTAL_NOTE=$((TOTAL_NOTE + n_note))

  # Classify.
  if [[ -n ${status_override:-} ]]; then
    status="$status_override"
    color="$C_REG"
    N_EMPTY=$((N_EMPTY + 1))
  elif ((rc == 77)); then
    status="BLOCKED"
    color="$C_BLOC"
    N_BLOCKED=$((N_BLOCKED + 1))
  elif ((n_fail == 0 && rc == 0)); then
    # A suite that carries baseline entries but is now green: the recorded
    # defect is gone. It passes, and it is called out separately because the
    # baseline entry is now a false claim about the tree and should be pruned.
    local_baselined=0
    for k in "${!BASELINE_REASON[@]}"; do
      [[ $k == "$name"$'\t'* ]] && { local_baselined=1; break; }
    done
    if ((local_baselined)); then
      status="RESOLVED"
      color="$C_BASE"
      N_RESOLVED=$((N_RESOLVED + 1))
      N_PASS=$((N_PASS + 1))
    else
      status="PASS"
      color="$C_PASS"
      N_PASS=$((N_PASS + 1))
    fi
  else
    # Every failure must be an individually recorded baseline entry.
    unmatched=0
    while IFS= read -r label; do
      [[ -n ${BASELINE_REASON["$name"$'\t'"$label"]+set} ]] || unmatched=$((unmatched + 1))
    done < <(awk -F'\t' '$1 == "FAIL" { print $3 }' "$results" 2>/dev/null)

    if ((unmatched == 0)) && ((n_fail > 0)); then
      status="BASELINE"
      color="$C_BASE"
      N_BASELINE=$((N_BASELINE + 1))
    elif ((unmatched == 0)) && ((n_fail == 0)); then
      # Red with no recorded failure: a suite that exits non-zero without
      # saying why. Treated as a regression because nothing explains it.
      status="REGRESSION"
      color="$C_REG"
      N_REGRESSION=$((N_REGRESSION + 1))
    else
      status="REGRESSION"
      color="$C_REG"
      N_REGRESSION=$((N_REGRESSION + 1))
    fi
  fi

  RESULTS+=("$status"$'\t'"$name"$'\t'"$n_pass"$'\t'"$n_fail"$'\t'"$n_skip"$'\t'"$n_note"$'\t'"$ms")

  RUN_DONE=$((RUN_DONE + 1))
done

if ((!QUIET)); then
  printf '\n%s%d suite(s) finished in %ds. Full report follows on stdout.%s\n\n' \
    "$C_DIM" "$RUN_DONE" "$(($(date +%s) - RUN_START))" "$C_OFF" >&2
fi

# The table is printed after every suite has run, not inline. Two reasons: the
# column widths can then be measured from the data rather than guessed, and a
# regression's detail lands *under* the table instead of pushing it around.

# _counts_string <pass> <fail> <skip> <note>
#
# The numbers a suite reported, right-aligned in fixed-width slots so they form
# a column. A zero count is left out entirely: a column of zeros says nothing,
# and an absent one still lines up because the slots are fixed width.
_counts_string() {
  local out=""
  out+="$(printf '%-7d' "$1")"
  (( $2 > 0 )) && out+="$(printf '%-7d' "$2")"
  (( $3 > 0 )) && out+="$(printf '%-5d' "$3")"
  (( $4 > 0 )) && out+="$(printf '%-5d' "$4")"
  printf '%s' "$out"
}

# Layout: status, suite name, then right-aligned counts, so the numbers form a
# column a reader can scan straight down.
# Column widths are measured from the run, not hardcoded, so the table stays
# aligned when a suite is added, renamed, or starts reporting a new counter.
W_STATUS=0
W_NAME=0
W_COUNTS=0
W_MS=0
for row in "${RESULTS[@]}"; do
  IFS=$'\t' read -r _st _nm _p _f _s _n _ms <<<"$row"
  ((${#_st} > W_STATUS)) && W_STATUS=${#_st}
  ((${#_nm} > W_NAME)) && W_NAME=${#_nm}
  _c="$(_counts_string "$_p" "$_f" "$_s" "$_n")"
  ((${#_c} > W_COUNTS)) && W_COUNTS=${#_c}
  ((${#_ms} > W_MS)) && W_MS=${#_ms}
done
((W_STATUS < 10)) && W_STATUS=10
((W_NAME < 12)) && W_NAME=12

if ((RUN_DONE == ${#SUITE_NAME[@]})); then
  printf '%sshell test suite%s  %s(%d suites)%s\n' \
    "$C_BOLD" "$C_OFF" "$C_DIM" "$RUN_DONE" "$C_OFF"
else
  printf '%sshell test suite%s  %s(%d of %d suites)%s\n' \
    "$C_BOLD" "$C_OFF" "$C_DIM" "$RUN_DONE" "${#SUITE_NAME[@]}" "$C_OFF"
fi
printf '%sThe four count columns are always, in order:  passed  failed  skipped  noted.%s\n' "$C_DIM" "$C_OFF"
printf '%sA count of zero is left blank. A NOTE is a recorded observation, not an\n' "$C_DIM"
printf '%sassertion - a documented surprise, or a host-dependent value. Notes are\n' "$C_DIM"
printf '%snever passes and never fails; they are counted separately so they can\n' "$C_DIM"
printf '%snever be mistaken for coverage. See the legend at the end of this run.%s\n\n' "$C_DIM" "$C_OFF"

for row in "${RESULTS[@]}"; do
  IFS=$'\t' read -r status name n_pass n_fail n_skip n_note ms <<<"$row"
  case "$status" in
  PASS) color="$C_PASS" ;;
  REGRESSION | EMPTY) color="$C_REG" ;;
  BLOCKED) color="$C_BLOC" ;;
  *) color="$C_BASE" ;;
  esac

  counts="$(_counts_string "$n_pass" "$n_fail" "$n_skip" "$n_note")"

  # Each field is padded to its measured width, so the suite names, the counts
  # and the timings are three independent columns rather than three ragged
  # lines that happen to end near each other. The count slots are left-aligned
  # inside the field so a row with no failures still puts its pass count in the
  # same column as every other row's.
  printf '  %s%-*s%s  %-*s  %s%-*s%*dms%s\n' \
    "$color" "$W_STATUS" "$status" "$C_OFF" \
    "$W_NAME" "$name" \
    "$C_DIM" "$W_COUNTS" "$counts" "$W_MS" "$ms" "$C_OFF"
done

# Detail for anything that is not a clean pass, and for everything when -v was
# asked for. Deferred so the table above stays a table.
for row in "${RESULTS[@]}"; do
  IFS=$'\t' read -r status name _p _f _s _n _ms <<<"$row"
  if [[ $status != "PASS" ]] || ((VERBOSE)); then
    printf '\n%s--- %s: %s ---%s\n' "$C_DIM" "$name" "$status" "$C_OFF"
    sed 's/^/  /' "$WORKROOT/$name.log" | grep -vE '^[[:space:]]*$' | head -60
    unmatched_labels=()
    while IFS= read -r label; do
      [[ -n ${BASELINE_REASON["$name"$'\t'"$label"]+set} ]] || unmatched_labels+=("$label")
    done < <(awk -F'\t' '$1 == "FAIL" { print $3 }' "$WORKROOT/$name.results" 2>/dev/null)
    if ((${#unmatched_labels[@]} > 0)); then
      printf '  %snot in the baseline:%s\n' "$C_REG" "$C_OFF"
      for l in "${unmatched_labels[@]}"; do printf '    %s\n' "$l"; done
    fi
  fi
done

# --- report ----------------------------------------------------------------

printf '\n%s\n' "$(printf -- '-%.0s' {1..72})"
printf '  %s%2d PASS%s' "$C_PASS" "$N_PASS" "$C_OFF"
((N_BASELINE > 0)) && printf '   %s%2d BASELINE%s' "$C_BASE" "$N_BASELINE" "$C_OFF"
((N_RESOLVED > 0)) && printf '   %s%2d RESOLVED%s' "$C_BASE" "$N_RESOLVED" "$C_OFF"
((N_BLOCKED > 0)) && printf '   %s%2d BLOCKED%s' "$C_BLOC" "$N_BLOCKED" "$C_OFF"
((N_EMPTY > 0)) && printf '   %s%2d NO-ASSERTIONS%s' "$C_REG" "$N_EMPTY" "$C_OFF"
((N_REGRESSION > 0)) && printf '   %s%2d REGRESSION%s' "$C_REG" "$N_REGRESSION" "$C_OFF"
((N_SKIPPED > 0)) && printf '   %s%2d filtered out%s' "$C_DIM" "$N_SKIPPED" "$C_OFF"
printf '\n'
printf '  %s%d assertions passed, %d failed, %d skipped, %d notes%s\n' \
  "$C_DIM" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP" "$TOTAL_NOTE" "$C_OFF"
printf '%s\n' "$(printf -- '-%.0s' {1..72})"

if ((N_BASELINE > 0)); then
  printf '\n%s%d suite(s) red by exactly their recorded baseline.%s\n' \
    "$C_BASE" "$N_BASELINE" "$C_OFF"
  printf '%sRun --baseline for the list, or --only <suite> -v to see them.%s\n' "$C_DIM" "$C_OFF"
fi
if ((N_RESOLVED > 0)); then
  printf '\n%s%d suite(s) are green but still carry a baseline entry.%s\n' \
    "$C_BASE" "$N_RESOLVED" "$C_OFF"
  printf '%sThe recorded defect is gone: prune its line from tests/shell/baseline.txt.%s\n' \
    "$C_DIM" "$C_OFF"
fi
if ((N_BLOCKED > 0)); then
  printf '\n%s%d suite(s) could not run here and are NOT passing.%s\n' \
    "$C_BLOC" "$N_BLOCKED" "$C_OFF"
fi
if ((N_EMPTY > 0)); then
  printf '\n%s%d suite(s) recorded no assertions at all.%s\n' "$C_REG" "$N_EMPTY" "$C_OFF"
  printf '%sA suite that asserts nothing demonstrates nothing, whatever it returns.\n' "$C_DIM"
  printf 'That is a suite-authoring bug, not a result: check the discovery rule and\n'
  printf 'that the suite actually reaches its assertions.%s\n' "$C_OFF"
  exit 1
fi
if ((N_REGRESSION > 0)); then
  printf '\n%s%d suite(s) regressed.%s\n' "$C_REG" "$N_REGRESSION" "$C_OFF"
  exit 1
fi
printf '\n%slegend%s\n' "$C_BOLD" "$C_OFF"
printf '  %spassed%s   an assertion that held.\n' "$C_BOLD" "$C_OFF"
printf '  %sfailed%s   an assertion that did not. On a non-PASS row every failure is\n' "$C_REG" "$C_OFF"
printf '           named under the table, and anything not in baseline.txt is a\n'
printf '           REGRESSION: an exit status of 1.\n'
printf '  %sskipped%s  behaviour that is explicitly unverified here, with the reason.\n' "$C_BASE" "$C_OFF"
printf '           A skip is never a pass; it is a visible gap in the total.\n'
printf '  %snoted%s    a recorded observation. NOT an assertion: a documented\n' "$C_BASE" "$C_OFF"
printf '           surprise pinned with its reason, a value that depends on this\n'
printf '           host or theme, or a finding. Full list in KNOWN_ISSUES.md.\n'
printf '  %stime%s     wall clock for the suite.\n\n' "$C_DIM" "$C_OFF"
exit 0
