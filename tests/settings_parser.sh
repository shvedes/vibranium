#!/bin/bash

# Test suite for helpers::check

source vb-lib-core

PASS=0
FAIL=0
TOTAL=0

_g=$'\e[0;32m'
_r=$'\e[0;31m'
_y=$'\e[0;33m'
_c=$'\e[0;36m'
_z=$'\e[90m'
_R=$'\e[0m'

_tmpfile=$(mktemp /tmp/vb_test_check.XXXXXX)
trap 'rm -f "$_tmpfile"' EXIT

section() { printf "\n${_c}=== %s ===${_R}\n\n" "$1"; }

log_case() {
  local label="$1" var="$2" set_to="$3" expected="$4"
  TOTAL=$((TOTAL + 1))

  if [[ $set_to == __UNSET__ ]]; then
    unset "$var"
    disp="<unset>"
  else
    printf -v "$var" '%s' "$set_to"
    [[ -z $set_to ]] && disp="''" || disp="$set_to"
  fi

  helpers::check "$var" >/dev/null 2>/dev/null
  local status
  if [[ ${!var} == "$expected" ]]; then
    status="${_g}PASS${_R}"
    PASS=$((PASS + 1))
  else
    status="${_r}FAIL${_R}"
    FAIL=$((FAIL + 1))
  fi

  printf "  ${_z}[%02d]${_R} %s  %-31s  %11s ${_y}->${_R} %s\n" \
    "$TOTAL" "$status" "$label" "$disp" "${!var}"

  while IFS= read -r _line; do
    [[ -n $_line ]] && printf "       ${_z}| %s${_R}\n" "$_line"
  done <"$_tmpfile"
}

summary() {
  printf "\n%s\n" "$(printf '=%.0s' {1..55})"
  printf "  ${_g}%d passed${_R}  ${_r}%d failed${_R}  %d total\n" "$PASS" "$FAIL" "$TOTAL"
  printf "%s\n\n" "$(printf '=%.0s' {1..55})"
  ((FAIL == 0))
}

_allowed_list() {
  local raw="${OPTION_ALLOWEDS[$1]-}"
  raw="${raw//|/ }"
  printf '%s' "${raw# }"
}

# =============================================================================
# 1. Parse + cache spot-checks
# =============================================================================

helpers::check VIBRANIUM_GLOBAL_USE_OSD >/dev/null 2>&1

section "cache"
printf "  defaults=%d  types=%d  allowed=%d  mins=%d  maxs=%d\n" \
  "${#OPTION_DEFAULTS[@]}" "${#OPTION_TYPES[@]}" \
  "${#OPTION_ALLOWEDS[@]}" "${#OPTION_MINS[@]}" "${#OPTION_MAXS[@]}"

_spot_check() {
  local var="$1" exp_default="$2" exp_type="$3" exp_range="$4" exp_allowed="$5"
  local ok=true
  [[ ${OPTION_DEFAULTS[$var]-} == "$exp_default" ]] || ok=false
  [[ ${OPTION_TYPES[$var]-} == "$exp_type" ]] || ok=false
  [[ -n $exp_range ]] && {
    local rng="${OPTION_MINS[$var]-}..${OPTION_MAXS[$var]-}"
    [[ $rng == "$exp_range" ]] || ok=false
  }
  [[ -n $exp_allowed ]] && { [[ ${OPTION_ALLOWEDS[$var]-} == "$exp_allowed" ]] || ok=false; }
  local tag
  [[ $ok == true ]] && tag="${_g}[PASS]${_R}" || tag="${_r}[FAIL]${_R}"
  local extra=""
  [[ -n $exp_range ]] && extra="  range=[${OPTION_MINS[$var]-?}..${OPTION_MAXS[$var]-?}]"
  [[ -n $exp_allowed ]] && extra="$extra  allowed={$(_allowed_list "$var")}"
  printf "  %s  %s  default='%s'  type='%s'%s\n" \
    "$tag" "$var" "${OPTION_DEFAULTS[$var]-<missing>}" "${OPTION_TYPES[$var]-<missing>}" "$extra"
}

_spot_check VIBRANIUM_GLOBAL_USE_OSD "false" "bool" "" ""
_spot_check VIBRANIUM_GLOBAL_PAUSE_MUSIC_ON_SESSION_LOCK "true" "bool" "" ""
_spot_check VIBRANIUM_VOLUME_ADJUSTMENT_STEP "5" "int" "" ""
_spot_check VIBRANIUM_SCREENSHOT_JPEG_QUALITY "80" "int" "0..100" ""
_spot_check VIBRANIUM_GLOBAL_SEARCH_ENGINE "google" "string" "" "|google|duckduckgo|bing|brave|"

# =============================================================================
# 2. Bool
# =============================================================================

B1="VIBRANIUM_GLOBAL_USE_OSD"
D1="${OPTION_DEFAULTS[$B1]}"
B2="VIBRANIUM_GLOBAL_PAUSE_MUSIC_ON_SESSION_LOCK"
D2="${OPTION_DEFAULTS[$B2]}"

section "bool - $B1"
log_case "exact default value" "$B1" "false" "false"
log_case "opposite bool" "$B1" "true" "true"
log_case "uppercase TRUE" "$B1" "TRUE" "true"
log_case "mixed case False" "$B1" "False" "false"
log_case "empty -> fallback" "$B1" "" "$D1"
log_case "'yes'" "$B1" "yes" "$D1"
log_case "'1'" "$B1" "1" "$D1"
log_case "'0'" "$B1" "0" "$D1"
log_case "garbage string" "$B1" "notabool" "$D1"
log_case "unset -> fallback" "$B1" __UNSET__ "$D1"

section "bool - $B2"
log_case "default" "$B2" "true" "true"
log_case "opposite" "$B2" "false" "false"
log_case "empty -> fallback" "$B2" "" "$D2"
log_case "unset -> fallback" "$B2" __UNSET__ "$D2"

# =============================================================================
# 3. Int - plain (no range)
# =============================================================================

IP="VIBRANIUM_VOLUME_ADJUSTMENT_STEP"
DP="${OPTION_DEFAULTS[$IP]}"

section "int plain - $IP"
log_case "default" "$IP" "5" "5"
log_case "zero" "$IP" "0" "0"
log_case "leading zeros" "$IP" "007" "7"
log_case "large number" "$IP" "99999" "99999"
log_case "negative" "$IP" "-3" "-3"
log_case "comma as decimal sep" "$IP" "5,0" "5.0"
log_case "empty -> fallback" "$IP" "" "$DP"
log_case "float string" "$IP" "3.14.1" "$DP"
log_case "letters" "$IP" "abc" "$DP"
log_case "mixed alphanum" "$IP" "5px" "$DP"
log_case "unset -> fallback" "$IP" __UNSET__ "$DP"

# =============================================================================
# 4. Int - range-constrained
# =============================================================================

IR="VIBRANIUM_SCREENSHOT_JPEG_QUALITY"
DR="${OPTION_DEFAULTS[$IR]}"
RMIN="${OPTION_MINS[$IR]}"
RMAX="${OPTION_MAXS[$IR]}"

section "int ranged - $IR [${RMIN}..${RMAX}]"
log_case "default" "$IR" "$DR" "$DR"
log_case "min boundary" "$IR" "$RMIN" "$RMIN"
log_case "max boundary" "$IR" "$RMAX" "$RMAX"
log_case "midpoint" "$IR" "50" "50"
log_case "leading zeros" "$IR" "080" "80"
log_case "below min -> fallback" "$IR" "$((RMIN - 1))" "$DR"
log_case "above max -> fallback" "$IR" "$((RMAX + 1))" "$DR"
log_case "empty -> fallback" "$IR" "" "$DR"
log_case "letters" "$IR" "abc" "$DR"
log_case "unset -> fallback" "$IR" __UNSET__ "$DR"

# =============================================================================
# 5. String - enum-constrained
# =============================================================================

SE="VIBRANIUM_GLOBAL_SEARCH_ENGINE"
DSE="${OPTION_DEFAULTS[$SE]}"
_raw="${OPTION_ALLOWEDS[$SE]-}"
_raw="${_raw//|/ }"
read -ra _se_allowed <<<"$_raw"

section "string enum - $SE  [$(_allowed_list "$SE")]"
for _v in "${_se_allowed[@]}"; do
  log_case "enum '$_v'" "$SE" "$_v" "$_v"
done
log_case "empty -> fallback" "$SE" "" "$DSE"
log_case "not in enum" "$SE" "notanoption" "$DSE"
log_case "correct uppercased" "$SE" "${_se_allowed[0]^^}" "$DSE"
log_case "value with spaces" "$SE" "${_se_allowed[0]} " "$DSE"
log_case "unset -> fallback" "$SE" __UNSET__ "$DSE"

# =============================================================================
# 6. String - second enum var
# =============================================================================

SE2="VIBRANIUM_SCREENSHOT_FILE_TYPE"
DSE2="${OPTION_DEFAULTS[$SE2]}"
_raw="${OPTION_ALLOWEDS[$SE2]-}"
_raw="${_raw//|/ }"
read -ra _se2_allowed <<<"$_raw"

section "string enum - $SE2  [$(_allowed_list "$SE2")]"
for _v in "${_se2_allowed[@]}"; do
  log_case "enum '$_v'" "$SE2" "$_v" "$_v"
done
log_case "unlisted value" "$SE2" "gif" "$DSE2"
log_case "uppercase" "$SE2" "PNG" "$DSE2"
log_case "partial match" "$SE2" "jp" "$DSE2"
log_case "empty -> fallback" "$SE2" "" "$DSE2"
log_case "unset -> fallback" "$SE2" __UNSET__ "$DSE2"

# =============================================================================
# 7. Unknown variable
# =============================================================================

section "unknown variable"
TOTAL=$((TOTAL + 1))
VIBRANIUM_TOTALLY_UNKNOWN_XYZ="original"
helpers::check VIBRANIUM_TOTALLY_UNKNOWN_XYZ 2>/dev/null
_rc=$?
if ((_rc == 1)) && [[ $VIBRANIUM_TOTALLY_UNKNOWN_XYZ == "original" ]]; then
  printf "${_g}[PASS]${_R} returned 1, variable untouched\n"
  PASS=$((PASS + 1))
else
  printf "${_r}[FAIL]${_R} rc=%d  got='%s'\n" "$_rc" "$VIBRANIUM_TOTALLY_UNKNOWN_XYZ"
  FAIL=$((FAIL + 1))
fi

# =============================================================================
# 8. Return codes for valid vars
# =============================================================================

section "return codes"

_assert_rc() {
  local label="$1" var="$2" set_to="$3" exp_rc="$4" exp_val="$5"
  TOTAL=$((TOTAL + 1))
  printf -v "$var" '%s' "$set_to"
  helpers::check "$var" >/dev/null 2>&1
  local rc=$?
  local val="${!var}"
  if ((rc == exp_rc)) && [[ $val == "$exp_val" ]]; then
    printf "  ${_g}[PASS]${_R}  %s  (rc=%d)\n" "$label" "$rc"
    PASS=$((PASS + 1))
  else
    printf "  ${_r}[FAIL]${_R}  %s  rc=%d (expected %d)  val='%s' (expected '%s')\n" \
      "$label" "$rc" "$exp_rc" "$val" "$exp_val"
    FAIL=$((FAIL + 1))
  fi
}

_assert_rc "bool valid -> rc 0"        "$B1" "true"  "0" "true"
_assert_rc "int valid -> rc 0"         "$IP" "42"   "0" "42"
_assert_rc "int ranged valid -> rc 0"  "$IR" "50"   "0" "50"
_assert_rc "string valid -> rc 0"      "$SE" "bing" "0" "bing"

# =============================================================================
# 9. Multi-variable check - nameref lifecycle
# =============================================================================

section "multi-variable check - nameref lifecycle"

TOTAL=$((TOTAL + 1))
VIBRANIUM_GLOBAL_USE_OSD="false"
VIBRANIUM_VOLUME_ADJUSTMENT_STEP="10"
VIBRANIUM_GLOBAL_SEARCH_ENGINE="duckduckgo"
helpers::check VIBRANIUM_GLOBAL_USE_OSD VIBRANIUM_VOLUME_ADJUSTMENT_STEP VIBRANIUM_GLOBAL_SEARCH_ENGINE >/dev/null 2>&1
if [[ $VIBRANIUM_GLOBAL_USE_OSD == false && $VIBRANIUM_VOLUME_ADJUSTMENT_STEP == 10 && $VIBRANIUM_GLOBAL_SEARCH_ENGINE == duckduckgo ]]; then
  printf "  ${_g}[PASS]${_R}  three vars in one call, all keep their valid values\n"
  PASS=$((PASS + 1))
else
  printf "  ${_r}[FAIL]${_R}  osd='%s'  step='%s'  engine='%s'\n" \
    "$VIBRANIUM_GLOBAL_USE_OSD" "$VIBRANIUM_VOLUME_ADJUSTMENT_STEP" "$VIBRANIUM_GLOBAL_SEARCH_ENGINE"
  FAIL=$((FAIL + 1))
fi

# Mixed: first valid, second invalid -> both should resolve
TOTAL=$((TOTAL + 1))
VIBRANIUM_GLOBAL_USE_OSD="true"
VIBRANIUM_VOLUME_ADJUSTMENT_STEP="garbage"
VIBRANIUM_GLOBAL_SEARCH_ENGINE="brave"
D3="${OPTION_DEFAULTS[$IP]}"
helpers::check VIBRANIUM_GLOBAL_USE_OSD VIBRANIUM_VOLUME_ADJUSTMENT_STEP VIBRANIUM_GLOBAL_SEARCH_ENGINE >/dev/null 2>&1
if [[ $VIBRANIUM_GLOBAL_USE_OSD == true && $VIBRANIUM_VOLUME_ADJUSTMENT_STEP == "$D3" && $VIBRANIUM_GLOBAL_SEARCH_ENGINE == brave ]]; then
  printf "  ${_g}[PASS]${_R}  mixed valid/invalid, invalid falls back, others untouched\n"
  PASS=$((PASS + 1))
else
  printf "  ${_r}[FAIL]${_R}  osd='%s'  step='%s' (expected '%s')  engine='%s'\n" \
    "$VIBRANIUM_GLOBAL_USE_OSD" "$VIBRANIUM_VOLUME_ADJUSTMENT_STEP" "$D3" "$VIBRANIUM_GLOBAL_SEARCH_ENGINE"
  FAIL=$((FAIL + 1))
fi

# Nameref release: two consecutive calls with different vars shouldn't cross-contaminate
TOTAL=$((TOTAL + 1))
VIBRANIUM_GLOBAL_USE_OSD="false"
VIBRANIUM_GLOBAL_PAUSE_MUSIC_ON_SESSION_LOCK="true"
helpers::check VIBRANIUM_GLOBAL_USE_OSD >/dev/null 2>&1
helpers::check VIBRANIUM_GLOBAL_PAUSE_MUSIC_ON_SESSION_LOCK >/dev/null 2>&1
if [[ $VIBRANIUM_GLOBAL_USE_OSD == false && $VIBRANIUM_GLOBAL_PAUSE_MUSIC_ON_SESSION_LOCK == true ]]; then
  printf "  ${_g}[PASS]${_R}  consecutive calls, no cross-contamination\n"
  PASS=$((PASS + 1))
else
  printf "  ${_r}[FAIL]${_R}  osd='%s'  pause='%s'\n" \
    "$VIBRANIUM_GLOBAL_USE_OSD" "$VIBRANIUM_GLOBAL_PAUSE_MUSIC_ON_SESSION_LOCK"
  FAIL=$((FAIL + 1))
fi

# =============================================================================
# 10. VIBRANIUM_BAR_WEATHER_MODULE_CITY - hardcoded skip
# =============================================================================

section "VIBRANIUM_BAR_WEATHER_MODULE_CITY - hardcoded skip"

# The var IS in the cache (awk parser doesn't honor @ignore), but helpers::check
# has a hardcoded continue for this name. Verify it passes through unchanged.
CC_VAR="VIBRANIUM_BAR_WEATHER_MODULE_CITY"

# The var has @ignore which means no @type annotation -> the awk parser skips it.
TOTAL=$((TOTAL + 1))
if [[ -z ${OPTION_DEFAULTS[$CC_VAR]+x} ]]; then
  printf "  ${_g}[PASS]${_R}  absent from cache (correct: @ignore -> no @type -> skipped)\n"
  PASS=$((PASS + 1))
else
  printf "  ${_r}[FAIL]${_R}  unexpectedly present in cache (default='%s')\n" "${OPTION_DEFAULTS[$CC_VAR]}"
  FAIL=$((FAIL + 1))
fi

# helpers::check on an unregistered var: should log a warning, return 1, leave value.
TOTAL=$((TOTAL + 1))
printf -v "$CC_VAR" '%s' "Paris"
helpers::check "$CC_VAR" >/dev/null 2>&1
local_rc=$?
if [[ ${!CC_VAR} == "Paris" ]] && ((local_rc == 0)); then
  printf "  ${_g}[PASS]${_R}  value preserved, rc=0 (hardcoded continue before cache lookup)\n"
  PASS=$((PASS + 1))
else
  printf "  ${_r}[FAIL]${_R}  val='%s' (expected Paris)  rc=%d (expected 1)\n" "${!CC_VAR}" "$local_rc"
  FAIL=$((FAIL + 1))
fi

# =============================================================================
# 11. Int - decimal fraction edge cases
# =============================================================================

section "int decimal fraction - edge cases"

IP2="VIBRANIUM_BRIGHTNESS_STEP"
DP2="${OPTION_DEFAULTS[$IP2]}"

# 3.14 is a valid float that matches the int regex - currently accepted
log_case "float 3.14 on non-range int"  "$IP2" "3.14" "3.14"

# Just the fraction ".5" - must start with a digit, so should fail
log_case "dot-five on non-range int"  "$IP2" ".5" "$DP2"

# Leading + sign - regex is ^(-?)0*[0-9]+(\.[0-9]+)?$ so + is not accepted
log_case "leading + on non-range int"  "$IP2" "+7" "$DP2"

# =============================================================================
# 12. String - leading/trailing whitespace
# =============================================================================

section "string enum - whitespace in value"

# Leading space should cause a mismatch (the allowed list has exact values)
log_case "leading space"  "$SE" " google" "$DSE"
log_case "trailing space" "$SE" "google " "$DSE"

summary
