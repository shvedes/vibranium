#!/usr/bin/env bash

# =============================================================================
# Test suite for helpers::parse_defaults and helpers::check
# Replace VIBRANIUM_* placeholder names with your actual variable names.
# =============================================================================

source vb-core-lib

# -----------------------------------------------------------------------------
# Test framework
# -----------------------------------------------------------------------------

PASS=0
FAIL=0
TOTAL=0

_g=$'\e[0;32m'   # green
_r=$'\e[0;31m'   # red
_c=$'\e[0;36m'   # cyan
_y=$'\e[0;33m'   # yellow
_z=$'\e[90m'     # gray
_R=$'\e[0m'      # reset

_tmpfile=$(mktemp /tmp/vb_test_check.XXXXXX)
trap 'rm -f "$_tmpfile"' EXIT

section() { printf "\n${_c}=== %s ===${_R}\n" "$1"; }

# log_case <label> <var_name> <inject_value|__UNSET__> <expected_value>
#
# KEY: helpers::check must run in the CURRENT shell (not a subshell) so that
# printf -v inside it actually updates the global variable. We redirect its
# output to a temp file, then display the file — no pipe around the function.
log_case() {
    local label="$1" var="$2" set_to="$3" expected="$4"
    TOTAL=$(( TOTAL + 1 ))

    if [[ $set_to == __UNSET__ ]]; then
        unset "$var"
        printf "  ${_z}[%02d] %-52s injected=<unset>${_R}\n" "$TOTAL" "$label"
    else
        printf -v "$var" '%s' "$set_to"
        printf "  ${_z}[%02d] %-52s injected='%s'${_R}\n" "$TOTAL" "$label" "$set_to"
    fi

    # Run in current shell — redirect stdout+stderr to file, NO pipe around the call
    helpers::check "$var" > "$_tmpfile" 2>&1
    # Now display any output from the check (warnings etc.)
    while IFS= read -r _line; do
        printf "       ${_z}[check] %s${_R}\n" "$_line"
    done < "$_tmpfile"

    local actual="${!var}"
    if [[ $actual == "$expected" ]]; then
        printf "       ${_g}PASS${_R}  got='%s'\n" "$actual"
        PASS=$(( PASS + 1 ))
    else
        printf "       ${_r}FAIL${_R}  got='%s'  expected='%s'\n" "$actual" "$expected"
        FAIL=$(( FAIL + 1 ))
    fi
}

summary() {
    printf "\n%s\n" "$(printf '=%.0s' {1..55})"
    printf "  ${_g}%d passed${_R}  ${_r}%d failed${_R}  %d total\n" "$PASS" "$FAIL" "$TOTAL"
    printf "%s\n" "$(printf '=%.0s' {1..55})"
    (( FAIL == 0 ))
}

# =============================================================================
# 1. Parse + cache dump
# =============================================================================

section "helpers::parse_defaults"
helpers::parse_defaults

printf "  Cache sizes:\n"
printf "    OPTION_DEFAULTS : %d entries\n" "${#OPTION_DEFAULTS[@]}"
printf "    OPTION_TYPES    : %d entries\n" "${#OPTION_TYPES[@]}"
printf "    OPTION_ALLOWEDS : %d entries\n" "${#OPTION_ALLOWEDS[@]}"
printf "    OPTION_MINS     : %d entries\n" "${#OPTION_MINS[@]}"
printf "    OPTION_MAXS     : %d entries\n" "${#OPTION_MAXS[@]}"

section "Cache spot-checks"
_spot_check() {
    local var="$1"
    local exp_default="$2" exp_type="$3" exp_range="$4" exp_allowed="$5"
    local ok=true

    [[ ${OPTION_DEFAULTS[$var]-} == "$exp_default" ]] || ok=false
    [[ ${OPTION_TYPES[$var]-}    == "$exp_type"    ]] || ok=false
    [[ -n $exp_range ]] && {
        local rng="${OPTION_MINS[$var]-}..${OPTION_MAXS[$var]-}"
        [[ $rng == "$exp_range" ]] || ok=false
    }
    [[ -n $exp_allowed ]] && {
        [[ ${OPTION_ALLOWEDS[$var]-} == "$exp_allowed" ]] || ok=false
    }

    local tag; [[ $ok == true ]] && tag="${_g}[PASS]${_R}" || tag="${_r}[FAIL]${_R}"
    printf "  %s %-50s default='%s'  type='%s'\n" \
        "$tag" "$var" "${OPTION_DEFAULTS[$var]-<missing>}" "${OPTION_TYPES[$var]-<missing>}"
    [[ -n $exp_range   ]] && printf "  %s                                                   range=[%s]\n"   "     " "${OPTION_MINS[$var]-?}..${OPTION_MAXS[$var]-?}"
    [[ -n $exp_allowed ]] && printf "  %s                                                   allowed='%s'\n" "     " "${OPTION_ALLOWEDS[$var]-<missing>}"
}

_spot_check VIBRANIUM_GLOBAL_USE_OSD                    "false"  "bool"   ""       ""
_spot_check VIBRANIUM_GLOBAL_PAUSE_MUSIC_ON_SESSION_LOCK "true"  "bool"   ""       ""
_spot_check VIBRANIUM_VOLUME_ADJUSTMENT_STEP            "5"      "int"    ""       ""
_spot_check VIBRANIUM_SCREENSHOT_JPEG_QUALITY           "80"     "int"    "0..100" ""
_spot_check VIBRANIUM_GLOBAL_SEARCH_ENGINE              "google" "string" ""       "google duckduckgo bing brave"

# =============================================================================
# 2. Bool
# =============================================================================

B1="VIBRANIUM_GLOBAL_USE_OSD"                       # default: false
B2="VIBRANIUM_GLOBAL_PAUSE_MUSIC_ON_SESSION_LOCK"   # default: true
D1="${OPTION_DEFAULTS[$B1]}"
D2="${OPTION_DEFAULTS[$B2]}"

section "bool — $B1"
log_case "valid: exact default value"    "$B1" "false"    "false"
log_case "valid: opposite bool"          "$B1" "true"     "true"
log_case "valid: uppercase TRUE"         "$B1" "TRUE"     "true"
log_case "valid: mixed case False"       "$B1" "False"    "false"
log_case "invalid: empty → fallback"     "$B1" ""         "$D1"
log_case "invalid: 'yes'"                "$B1" "yes"      "$D1"
log_case "invalid: '1'"                  "$B1" "1"        "$D1"
log_case "invalid: '0'"                  "$B1" "0"        "$D1"
log_case "invalid: garbage string"       "$B1" "notabool" "$D1"
log_case "invalid: unset → fallback"     "$B1" __UNSET__  "$D1"

section "bool — $B2"
log_case "valid: default"                "$B2" "true"     "true"
log_case "valid: opposite"               "$B2" "false"    "false"
log_case "invalid: empty → fallback"     "$B2" ""         "$D2"
log_case "invalid: unset → fallback"     "$B2" __UNSET__  "$D2"

# =============================================================================
# 3. Int — plain (no range)
# =============================================================================

IP="VIBRANIUM_VOLUME_ADJUSTMENT_STEP"   # default: 5, no range
DP="${OPTION_DEFAULTS[$IP]}"

section "int plain — $IP"
log_case "valid: default"                "$IP" "5"       "5"
log_case "valid: zero"                   "$IP" "0"       "0"
log_case "valid: leading zeros stripped" "$IP" "007"     "7"
log_case "valid: large number"           "$IP" "99999"   "99999"
log_case "valid: negative"               "$IP" "-3"      "-3"
log_case "valid: comma as decimal sep"   "$IP" "5,0"     "5.0"
log_case "invalid: empty → fallback"     "$IP" ""        "$DP"
log_case "invalid: float string"         "$IP" "3.14.1"  "$DP"
log_case "invalid: letters"              "$IP" "abc"     "$DP"
log_case "invalid: mixed alphanum"       "$IP" "5px"     "$DP"
log_case "invalid: unset → fallback"     "$IP" __UNSET__ "$DP"

# =============================================================================
# 4. Int — range-constrained
# =============================================================================

IR="VIBRANIUM_SCREENSHOT_JPEG_QUALITY"   # default: 80, range: 0..100
DR="${OPTION_DEFAULTS[$IR]}"
RMIN="${OPTION_MINS[$IR]}"
RMAX="${OPTION_MAXS[$IR]}"

section "int ranged — $IR  [${RMIN}..${RMAX}]"
log_case "valid: default"                "$IR" "$DR"                   "$DR"
log_case "valid: min boundary"           "$IR" "$RMIN"                 "$RMIN"
log_case "valid: max boundary"           "$IR" "$RMAX"                 "$RMAX"
log_case "valid: midpoint"               "$IR" "50"                    "50"
log_case "valid: leading zeros stripped" "$IR" "080"                   "80"
log_case "invalid: below min → fallback" "$IR" "$(( RMIN - 1 ))"      "$DR"
log_case "invalid: above max → fallback" "$IR" "$(( RMAX + 1 ))"      "$DR"
log_case "invalid: empty → fallback"     "$IR" ""                      "$DR"
log_case "invalid: letters"              "$IR" "abc"                   "$DR"
log_case "invalid: unset → fallback"     "$IR" __UNSET__               "$DR"

# =============================================================================
# 5. String — enum-constrained
# =============================================================================

SE="VIBRANIUM_GLOBAL_SEARCH_ENGINE"   # default: google, allowed: google duckduckgo bing brave
DSE="${OPTION_DEFAULTS[$SE]}"
read -ra _se_allowed <<< "${OPTION_ALLOWEDS[$SE]-}"

section "string enum — $SE  [${OPTION_ALLOWEDS[$SE]-}]"
for _v in "${_se_allowed[@]}"; do
    log_case "valid: enum value '$_v'"   "$SE" "$_v" "$_v"
done
log_case "invalid: empty → fallback"     "$SE" ""                        "$DSE"
log_case "invalid: not in enum"          "$SE" "notanoption"             "$DSE"
log_case "invalid: correct value uppercased" "$SE" "${_se_allowed[0]^^}" "$DSE"
log_case "invalid: value with spaces"    "$SE" "${_se_allowed[0]} "      "$DSE"
log_case "invalid: unset → fallback"     "$SE" __UNSET__                 "$DSE"

# =============================================================================
# 6. String — second enum var (if you have one — swap var name as needed)
# =============================================================================

SE2="VIBRANIUM_SCREENSHOT_FILE_TYPE"   # default: jpeg, allowed: png jpeg ppm
DSE2="${OPTION_DEFAULTS[$SE2]}"
read -ra _se2_allowed <<< "${OPTION_ALLOWEDS[$SE2]-}"

section "string enum — $SE2  [${OPTION_ALLOWEDS[$SE2]-}]"
for _v in "${_se2_allowed[@]}"; do
    log_case "valid: enum value '$_v'"   "$SE2" "$_v" "$_v"
done
log_case "invalid: unlisted value"       "$SE2" "gif"         "$DSE2"
log_case "invalid: uppercase"            "$SE2" "PNG"         "$DSE2"
log_case "invalid: partial match"        "$SE2" "jp"          "$DSE2"
log_case "invalid: empty → fallback"     "$SE2" ""            "$DSE2"
log_case "invalid: unset → fallback"     "$SE2" __UNSET__     "$DSE2"

# =============================================================================
# 7. Unknown variable — should warn and return 1, not touch the variable
# =============================================================================

section "unknown variable"
TOTAL=$(( TOTAL + 1 ))
VIBRANIUM_TOTALLY_UNKNOWN_XYZ="original"
helpers::check VIBRANIUM_TOTALLY_UNKNOWN_XYZ 2>/dev/null
_rc=$?
if (( _rc == 1 )) && [[ $VIBRANIUM_TOTALLY_UNKNOWN_XYZ == "original" ]]; then
    printf "       ${_g}PASS${_R}  returned 1, variable untouched\n"
    PASS=$(( PASS + 1 ))
else
    printf "       ${_r}FAIL${_R}  rc=%d  got='%s'\n" "$_rc" "$VIBRANIUM_TOTALLY_UNKNOWN_XYZ"
    FAIL=$(( FAIL + 1 ))
fi

# =============================================================================
# Summary
# =============================================================================

summary
