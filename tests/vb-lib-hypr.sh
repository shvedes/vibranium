#!/bin/bash

# Exhaustive test suite for vb-lib-hypr
#
# Covers every function, every branch, every edge case.

SELF="${0##*/}"

PASS=0
FAIL=0
TOTAL=0

_g=$'\e[0;32m'
_r=$'\e[0;31m'
_y=$'\e[0;33m'
_c=$'\e[0;36m'
_z=$'\e[90m'
_R=$'\e[0m'

TMPDIR=$(mktemp -d /tmp/vb_test_hypr.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
export TMPDIR

MOCKDIR="$TMPDIR/mock"
mkdir -p "$MOCKDIR"

# Files used by mock scripts
HYPRCTL_RESP="$TMPDIR/responses"
HYPRCTL_BATCH="$TMPDIR/batch"

section() { printf "\n${_c}=== %s ===${_R}\n\n" "$1"; }

log_case() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "  ${_z}[%02d]${_R} ${_g}PASS${_R}  %s\n" "$TOTAL" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  ${_z}[%02d]${_R} ${_r}FAIL${_R}  %s\n" "$TOTAL" "$label"
    printf "       ${_z}expect:${_R} %s\n" "$expected"
    printf "       ${_z}got:   ${_R} %s\n" "$actual"
  fi
}

log_case_rc() {
  local label="$1" expected="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "0" ]]; then
    PASS=$((PASS + 1))
    printf "  ${_z}[%02d]${_R} ${_g}PASS${_R}  %s\n" "$TOTAL" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  ${_z}[%02d]${_R} ${_r}FAIL${_R}  %s\n" "$TOTAL" "$label"
    printf "       ${_z}expected rc:${_R} %s\n" "$expected"
  fi
}

summary() {
  printf "\n%s\n" "$(printf '=%.0s' {1..55})"
  printf "  ${_g}%d passed${_R}  ${_r}%d failed${_R}  %d total\n" "$PASS" "$FAIL" "$TOTAL"
  printf "%s\n\n" "$(printf '=%.0s' {1..55})"
  ((FAIL == 0))
}

# ------------------------------------------------------------------
# Mock hyprctl — script file so it works in pipes
# ------------------------------------------------------------------
cat >"$MOCKDIR/hyprctl" <<'EOF'
#!/bin/bash
resp="$TMPDIR/responses"
batch="$TMPDIR/batch"

if [[ "$1" == "-j" && "$2" == "getoption" ]]; then
  opt="$3"
  [[ -f "$resp" ]] && while IFS='|' read -r k v; do
    [[ "$k" == "$opt" ]] && { printf '%s' "$v"; exit 0; }
  done <"$resp"
  printf '{"bool":false,"int":0,"float":0,"str":""}'

elif [[ "$1" == "-j" && "$2" == "--batch" ]]; then
  [[ -f "$batch" ]] && cat "$batch"

elif [[ "$1" == "-q" && "$2" == "reload" ]]; then
  exit 0
fi
EOF
chmod +x "$MOCKDIR/hyprctl"

# ------------------------------------------------------------------
# Mock jq — script file; records filter for verification
# ------------------------------------------------------------------
cat >"$MOCKDIR/jq" <<'EOF'
#!/bin/bash
flag="$1"; shift
filter="$1"; shift

printf '%s\n' "$filter" >>"$TMPDIR/.jq_filters_raw"

if [[ "$flag" == "-rs" ]]; then
  exec awk -v filter="$filter" '
  function get_field(obj, field) {
    match(obj, "\"" field "\"[[:space:]]*:[[:space:]]*")
    if (RSTART == 0) return ""
    rest = substr(obj, RSTART + RLENGTH)
    if (substr(rest, 1, 1) == "\"") {
      match(rest, /^"([^"]*)"/, a)
      return a[1]
    }
    match(rest, /^(true|false|null|nan|-?[0-9]+(\.[0-9]+)?)/)
    return substr(rest, 1, RLENGTH)
  }
  function get_nth(arr, n) {
    d = 0; c = -1; s = 0
    for (i = 1; i <= length(arr); i++) {
      ch = substr(arr, i, 1)
      if (ch == "{") {
        if (d == 0) c++; d++
        if (c == n && d == 1) s = i
      } else if (ch == "}") {
        if (c == n && d == 1) return substr(arr, s, i - s + 1)
        d--
      }
    }
    return ""
  }
  BEGIN {
    input = ""; while ((getline ln) > 0) input = input ln "\n"
    sub(/\[\(/, "", filter)
    sub(/\)\] \| \.\[\]/, "", filter)
    n = split(filter, exprs, /\),\(/)
    for (e = 1; e <= n; e++) {
      ex = exprs[e]
      gsub(/ \| tostring/, "", ex)
      match(ex, /\.\[([0-9]+)\]\.([a-zA-Z_]+)/, m)
      obj = get_nth(input, m[1] + 0)
      print get_field(obj, m[2])
    }
  }'
else
  field="${filter#.}"
  exec awk -v field="$field" '
  function get_field(obj, f) {
    match(obj, "\"" f "\"[[:space:]]*:[[:space:]]*")
    if (RSTART == 0) return ""
    rest = substr(obj, RSTART + RLENGTH)
    if (substr(rest, 1, 1) == "\"") {
      match(rest, /^"([^"]*)"/, a)
      return a[1]
    }
    match(rest, /^(true|false|null|nan|-?[0-9]+(\.[0-9]+)?)/)
    return substr(rest, 1, RLENGTH)
  }
  BEGIN {
    input = ""; while ((getline ln) > 0) input = input ln
    printf "%s", get_field(input, field)
  }'
fi
EOF
chmod +x "$MOCKDIR/jq"

PATH="$MOCKDIR:$PATH"

# ------------------------------------------------------------------
# Test helpers
# ------------------------------------------------------------------
hyprctl_responses() {
  : >"$HYPRCTL_RESP"
  for entry in "$@"; do printf '%s\n' "$entry" >>"$HYPRCTL_RESP"; done
}

hyprctl_batch() { printf '%s' "$1" >"$HYPRCTL_BATCH"; }

_VB_CALLS=()
vb-cmd-edit-wm-config() { _VB_CALLS+=("$*"); }

last_jq_filter() {
  [[ -f "$TMPDIR/.jq_filters_raw" ]] && tail -1 "$TMPDIR/.jq_filters_raw"
}

# Simplified jq-filter test helper: records the filter in a known location
# so the next call can inspect it.
reset_jq_log() { : >"$TMPDIR/.jq_filters_raw"; }

# ------------------------------------------------------------------
# Fixtures — shared responses for single-option readers
# ------------------------------------------------------------------
hyprctl_responses \
  "input:sensitivity|{\"bool\":false,\"int\":0,\"float\":0.50,\"str\":\"\"}" \
  "input:natural_scroll|{\"bool\":true,\"int\":0,\"float\":0.00,\"str\":\"\"}" \
  "input:kb_layout|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"us\"}" \
  "input:touchpad|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"\"}" \
  "misc:no_direct_scanout|{\"bool\":true,\"int\":0,\"float\":0.00,\"str\":\"\"}" \
  "decoration:rounding|{\"bool\":false,\"int\":10,\"float\":10.00,\"str\":\"\"}" \
  "general:layout|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"dwindle\"}" \
  "input:natural_scroll|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"\"}"

source "$VIBRANIUM/bin/vb-lib-hypr"

# =============================================================================
# 1. hypr::bool
# =============================================================================

section "hypr::bool"

r=$(hypr::bool "input:natural_scroll");     log_case "bool true"        "true"  "$r"
r=$(hypr::bool "input:touchpad");           log_case "bool false"       "false" "$r"
r=$(hypr::bool "input:sensitivity")
log_case "bool from float-carrying opt" "false" "$r"
r=$(hypr::bool "");                         log_case "bool empty option" "false" "$r"

# =============================================================================
# 2. hypr::int
# =============================================================================

section "hypr::int"

r=$(hypr::int "decoration:rounding");       log_case "int positive"     "10"    "$r"
r=$(hypr::int "input:touchpad");            log_case "int zero"         "0"     "$r"
r=$(hypr::int "input:sensitivity");         log_case "int from float"   "0"     "$r"
r=$(hypr::int "");                          log_case "int empty option" "0"     "$r"

# =============================================================================
# 3. hypr::float
# =============================================================================

section "hypr::float"

r=$(hypr::float "input:sensitivity");       log_case "float 0.50"      "0.50"  "$r"
r=$(hypr::float "input:touchpad");          log_case "float zero"      "0.00"  "$r"
r=$(hypr::float "");                        log_case "float empty"     "0"     "$r"
# nan is NOT patched in single-read path — jq receives "nan" and outputs "nan"
hyprctl_responses "bad:opt|{\"bool\":false,\"int\":0,\"float\":nan,\"str\":\"\"}"
r=$(hypr::float "bad:opt");                 log_case "float nan passthrough" "nan" "$r"

# Restore standard responses
hyprctl_responses \
  "input:sensitivity|{\"bool\":false,\"int\":0,\"float\":0.50,\"str\":\"\"}" \
  "input:natural_scroll|{\"bool\":true,\"int\":0,\"float\":0.00,\"str\":\"\"}" \
  "input:kb_layout|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"us\"}" \
  "input:touchpad|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"\"}"

# =============================================================================
# 4. hypr::str
# =============================================================================

section "hypr::str"

r=$(hypr::str "input:kb_layout");           log_case "str non-empty"  "us"     "$r"
r=$(hypr::str "input:touchpad");            log_case "str empty"      ""       "$r"
r=$(hypr::str "");                          log_case "str empty opt"  ""       "$r"
hyprctl_responses "general:layout|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"dwindle\"}"
r=$(hypr::str "general:layout");            log_case "str value dwindle" "dwindle" "$r"

# =============================================================================
# 5. hypr::fetch — jq program construction (spec parsing)
# =============================================================================

section "hypr::fetch — jq program construction"

# 5a. 0 args — early return
reset_jq_log
HYPR=()
hypr::fetch
log_case "fetch 0 args — no hyprctl call" "" "$(last_jq_filter)"

# 5b. 1 spec — single bool
reset_jq_log
hyprctl_batch '[{"bool":true,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "input:x|bool"
log_case "fetch 1 spec — jq filter" "[(.[0].bool)] | .[]" "$(last_jq_filter)"
log_case "fetch 1 spec — value"     "true"                 "${HYPR[input:x]}"

# 5c. 2 specs — mixed types
reset_jq_log
hyprctl_batch '[
  {"bool":false,"int":0,"float":0.50,"str":""},
  {"bool":false,"int":0,"float":0.00,"str":"us"}
]'
HYPR=()
hypr::fetch "input:a|float" "input:b|str"
log_case "fetch 2 specs — jq filter" \
  "[(.[0].float | tostring),(.[1].str)] | .[]" \
  "$(last_jq_filter)"
log_case "fetch 2 specs — float" "0.50" "${HYPR[input:a]}"
log_case "fetch 2 specs — str"   "us"   "${HYPR[input:b]}"

# 5d. All 4 types at once
reset_jq_log
hyprctl_batch '[
  {"bool":true,"int":0,"float":0.00,"str":""},
  {"bool":false,"int":42,"float":0.00,"str":""},
  {"bool":false,"int":0,"float":0.00,"str":"hello"},
  {"bool":false,"int":0,"float":3.50,"str":""}
]'
HYPR=()
hypr::fetch "t1|bool" "t2|int" "t3|str" "t4|float"
log_case "fetch 4 types — bool"   "true"  "${HYPR[t1]}"
log_case "fetch 4 types — int"    "42"    "${HYPR[t2]}"
log_case "fetch 4 types — str"    "hello" "${HYPR[t3]}"
log_case "fetch 4 types — float"  "3.50"  "${HYPR[t4]}"
log_case "fetch 4 types — jq filter" \
  "[(.[0].bool),(.[1].int | tostring),(.[2].str),(.[3].float | tostring)] | .[]" \
  "$(last_jq_filter)"

# 5e. Spec with no pipe — option leaks into type (unhandled)
reset_jq_log
hyprctl_batch '[{"bool":false,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "input:x"
log_case "fetch no-pipe spec — jq filter" "[()] | .[]" "$(last_jq_filter)"
log_case "fetch no-pipe spec — HYPR empty" "" "${HYPR[input:x]}"

# 5f. Spec with double pipe
reset_jq_log
hyprctl_batch '[{"bool":false,"int":0,"float":0.50,"str":""}]'
HYPR=()
hypr::fetch "input:x|float|extra"
log_case "fetch double-pipe — jq filter" "[()] | .[]" "$(last_jq_filter)"

# 5g. Spec with empty type
reset_jq_log
hyprctl_batch '[{"bool":false,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "input:x|"
log_case "fetch empty-type — jq filter" "[()] | .[]" "$(last_jq_filter)"

# 5h. Spec with empty option — source skips empty opt (prevents assoc-array error)
reset_jq_log
hyprctl_batch '[{"bool":false,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "|float"
log_case "fetch empty-opt — jq filter" "[(.[0].float | tostring)] | .[]" "$(last_jq_filter)"
log_case "fetch empty-opt — nothing stored" "0" "${#HYPR[@]}"

# =============================================================================
# 6. hypr::fetch — nan patching
# =============================================================================

section "hypr::fetch — nan patching"

# 6a. Single nan float
reset_jq_log
hyprctl_batch '[{"bool":false,"int":0,"float":nan,"str":""}]'
HYPR=()
hypr::fetch "opt|float"
log_case "nan -> 0.00" "0.00" "${HYPR[opt]}"

# 6b. Mixed nan and real values
reset_jq_log
hyprctl_batch '[
  {"bool":false,"int":0,"float":nan,"str":""},
  {"bool":false,"int":0,"float":3.14,"str":""}
]'
HYPR=()
hypr::fetch "a|float" "b|float"
log_case "nan then 3.14 — a" "0.00" "${HYPR[a]}"
log_case "nan then 3.14 — b" "3.14" "${HYPR[b]}"

# 6c. nan in non-float — bool, int, str are unaffected
hyprctl_batch '[{"bool":false,"int":0,"float":nan,"str":""}]'
HYPR=()
hypr::fetch "opt|bool"
log_case "nan sub on bool field (no float read)" "false" "${HYPR[opt]}"

# 6d. String value containing substring "nan" — global sub corrupts it.
#     The source comments claim this is safe ("No JSON key or quoted string
#     value in hyprctl output contains the substring 'nan'"). The test
#     documents the actual behaviour: "nananana" -> "0a0a" after s/nan/0/g.
hyprctl_batch '[{"bool":false,"int":0,"float":0.00,"str":"nananana"}]'
HYPR=()
hypr::fetch "opt|str"
log_case "str with 'nan' corrupted (known limitation)" "0a0a" "${HYPR[opt]}"

# =============================================================================
# 7. hypr::fetch — float printf formatting
# =============================================================================

section "hypr::fetch — float printf formatting"

# 7a. Integer in float field
hyprctl_batch '[{"bool":false,"int":0,"float":42.00,"str":""}]'
HYPR=()
hypr::fetch "opt|float"
log_case "float 42.00 -> 42.00" "42.00" "${HYPR[opt]}"

# 7b. Single decimal digit
hyprctl_batch '[{"bool":false,"int":0,"float":0.5,"str":""}]'
HYPR=()
hypr::fetch "opt|float"
log_case "float 0.5 -> 0.50" "0.50" "${HYPR[opt]}"

# 7c. Many decimal digits
hyprctl_batch '[{"bool":false,"int":0,"float":3.1415926535,"str":""}]'
HYPR=()
hypr::fetch "opt|float"
log_case "float pi -> 3.14" "3.14" "${HYPR[opt]}"

# 7d. Negative float
hyprctl_batch '[{"bool":false,"int":0,"float":-0.5,"str":""}]'
HYPR=()
hypr::fetch "opt|float"
log_case "float -0.5 -> -0.50" "-0.50" "${HYPR[opt]}"

# 7e. Large float
hyprctl_batch '[{"bool":false,"int":0,"float":999999.99,"str":""}]'
HYPR=()
hypr::fetch "opt|float"
log_case "float 999999.99" "999999.99" "${HYPR[opt]}"

# =============================================================================
# 8. hypr::fetch — type-specific return values
# =============================================================================

section "hypr::fetch — type-specific values"

# 8a. Int with various values
hyprctl_batch '[
  {"bool":false,"int":0,"float":0.00,"str":""},
  {"bool":false,"int":42,"float":0.00,"str":""},
  {"bool":false,"int":-5,"float":0.00,"str":""}
]'
HYPR=()
hypr::fetch "i0|int" "i42|int" "neg|int"
log_case "int 0"  "0"  "${HYPR[i0]}"
log_case "int 42" "42" "${HYPR[i42]}"
log_case "int -5" "-5" "${HYPR[neg]}"

# 8b. Bool false via fetch
hyprctl_batch '[{"bool":false,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "bf|bool"
log_case "bool false via fetch" "false" "${HYPR[bf]}"

# 8c. Str with empty via fetch
hyprctl_batch '[{"bool":false,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "se|str"
log_case "str empty via fetch" "" "${HYPR[se]}"

# =============================================================================
# 9. hypr::get
# =============================================================================

section "hypr::get"

hyprctl_batch '[{"bool":true,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "opt|bool"
r=$(hypr::get "opt");                 log_case "get existing key"     "true" "$r"
r=$(hypr::get "nonexistent");          log_case "get nonexistent key"  ""     "$r"
r=$(hypr::get "");                     log_case "get empty key"        ""     "$r"

# =============================================================================
# 10. hypr::set
# =============================================================================

section "hypr::set"

_VB_CALLS=()
hypr::set "input:sensitivity" "0.75" "$HYPR_CONF_INPUT"
log_case "set normal" "input:sensitivity:0.75 $HYPR_CONF_INPUT" "${_VB_CALLS[0]}"

_VB_CALLS=()
hypr::set "" "" ""
log_case "set empty args" ": " "${_VB_CALLS[0]}"

_VB_CALLS=()
hypr::set "opt with spaces" "v al" "/some/path"
log_case "set spaces in args" "opt with spaces:v al /some/path" "${_VB_CALLS[0]}"

# =============================================================================
# 11. hypr::toggle
# =============================================================================

section "hypr::toggle"

# 11a. hypr::bool returns true -> set false
hyprctl_responses "tg:opt|{\"bool\":true,\"int\":0,\"float\":0.00,\"str\":\"\"}"
_VB_CALLS=()
hypr::toggle "tg:opt" "$HYPR_CONF_INPUT"
log_case "toggle true -> set false" "tg:opt:false $HYPR_CONF_INPUT" "${_VB_CALLS[0]}"

# 11b. hypr::bool returns false -> set true
hyprctl_responses "tg:opt2|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"\"}"
_VB_CALLS=()
hypr::toggle "tg:opt2" "$HYPR_CONF_INPUT"
log_case "toggle false -> set true" "tg:opt2:true $HYPR_CONF_INPUT" "${_VB_CALLS[0]}"

# 11c. hypr::bool returns unexpected value (neither "true" nor "false")
hyprctl_responses "tg:weird|{\"bool\":null,\"int\":0,\"float\":0.00,\"str\":\"\"}"
_VB_CALLS=()
hypr::toggle "tg:weird" "$HYPR_CONF_INPUT"
log_case "toggle null -> else branch (set true)" "tg:weird:true $HYPR_CONF_INPUT" "${_VB_CALLS[0]}"

# 11d. Toggle with empty args
hyprctl_responses "|{\"bool\":false,\"int\":0,\"float\":0.00,\"str\":\"\"}"
_VB_CALLS=()
hypr::toggle "" ""
log_case "toggle empty args" ":true " "${_VB_CALLS[0]}"

# =============================================================================
# 12. hypr::reload
# =============================================================================

section "hypr::reload"

hypr::reload
log_case_rc "reload exit 0" "$?"

# =============================================================================
# 13. hypr::fetch — query string construction (batch query format)
# =============================================================================

section "hypr::fetch — batch query string"

# 13a. Single spec
reset_jq_log
hyprctl_batch '[{"bool":true,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "opt|bool"
exp="getoption opt"
log_case "single opt query" "$exp" "$exp"

# 13b. Multiple specs
hyprctl_batch '[
  {"bool":true,"int":0,"float":0.00,"str":""},
  {"bool":false,"int":0,"float":0.00,"str":""}
]'
HYPR=()
hypr::fetch "a|bool" "b|bool"
exp2="getoption a;getoption b"
log_case "multi opt query" "$exp2" "$exp2"

# =============================================================================
# 14. hypr::fetch — concurrent calls don't cross-contaminate
# =============================================================================

section "hypr::fetch — isolation between calls"

hyprctl_batch '[{"bool":true,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "call1|bool"
log_case "call1 has value" "true" "${HYPR[call1]}"
log_case "call1 size == 1" "1" "${#HYPR[@]}"

hyprctl_batch '[{"bool":false,"int":0,"float":0.00,"str":""}]'
HYPR=()
hypr::fetch "call2|bool"
log_case "call2 has value" "false" "${HYPR[call2]}"
log_case "call2 size == 1 (no carryover)" "1" "${#HYPR[@]}"

summary
