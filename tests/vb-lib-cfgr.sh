#!/bin/bash

# Test suite for vb-lib-cfgr
# Tests internal data transformations -- everything before rofi is called.

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

TMPDIR=$(mktemp -d /tmp/vb_test_cfgr.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

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

summary() {
  printf "\n%s\n" "$(printf '=%.0s' {1..55})"
  printf "  ${_g}%d passed${_R}  ${_r}%d failed${_R}  %d total\n" "$PASS" "$FAIL" "$TOTAL"
  printf "%s\n\n" "$(printf '=%.0s' {1..55})"
  ((FAIL == 0))
}

# ------------------------------------------------------------------
# Sandboxed settings + defaults
# ------------------------------------------------------------------
SETTINGS="$TMPDIR/settings"
cat >"$SETTINGS" <<'EOF'
VIBRANIUM_MOCK_BOOL=true
VIBRANIUM_MOCK_INT=42
VIBRANIUM_MOCK_STR=h264
VIBRANIUM_MOCK_RANGED=50
VIBRANIUM_MOCK_BOOL2=false
EOF

DEFAULTS="$TMPDIR/vb-core-defaults"
cat >"$DEFAULTS" <<'EOF'
# @type bool
VIBRANIUM_MOCK_BOOL=true

# @type int
VIBRANIUM_MOCK_INT=42

# @type string
# @values h264 hevc av1
VIBRANIUM_MOCK_STR="h264"

# @type int
# @range 0..100
VIBRANIUM_MOCK_RANGED=50

# @type bool
VIBRANIUM_MOCK_BOOL2=false
EOF

export VIBRANIUM_USER_SETTINGS="$SETTINGS"
export VIBRANIUM_PATH="$TMPDIR"

# Source libraries first, THEN mock rofi so our override wins.
source "$VIBRANIUM/bin/vb-lib-core" 2>/dev/null
source "$VIBRANIUM/bin/vb-lib-cfgr"

# Mock rofi -- we only test internal data, not the menu interaction.
helpers::ui::menu() {
  local var_name="$1"
  printf -v "$var_name" '%s' ""
}
notify-send() { :; }

# Pre-populate OPTION_* caches so helpers::check doesn't fork awk.
OPTION_DEFAULTS=(
  [VIBRANIUM_MOCK_BOOL]=true
  [VIBRANIUM_MOCK_INT]=42
  [VIBRANIUM_MOCK_STR]=h264
  [VIBRANIUM_MOCK_RANGED]=50
  [VIBRANIUM_MOCK_BOOL2]=false
)
OPTION_TYPES=(
  [VIBRANIUM_MOCK_BOOL]=bool
  [VIBRANIUM_MOCK_INT]=int
  [VIBRANIUM_MOCK_STR]=string
  [VIBRANIUM_MOCK_RANGED]=int
  [VIBRANIUM_MOCK_BOOL2]=bool
)
OPTION_ALLOWEDS=(
  [VIBRANIUM_MOCK_STR]="|h264|hevc|av1|"
)
OPTION_MINS=(
  [VIBRANIUM_MOCK_RANGED]=0
)
OPTION_MAXS=(
  [VIBRANIUM_MOCK_RANGED]=100
)

# Bring sandbox vars into scope for indirect expansion in item::*
source "$SETTINGS"

# =============================================================================
# 1. cfgr::item::* -- array population
# =============================================================================

section "cfgr::item::bool"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::bool --var VIBRANIUM_MOCK_BOOL --label "Flash screen"
log_case "bool display"                "Flash screen : true"    "${_CFGR_ITEMS[0]}"
log_case "bool dispatch (no hook)"     "bool:VIBRANIUM_MOCK_BOOL"       "${_CFGR_DISPATCH[0]}"
log_case "bool icon (empty)"           ""                                "${_CFGR_ICONS[0]}"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::bool --var VIBRANIUM_MOCK_BOOL2 --label "Pause" --hook "_restart" --icon "audio"
log_case "bool with hook+icon display" "Pause : false"                  "${_CFGR_ITEMS[0]}"
log_case "bool with hook dispatch"     "bool:VIBRANIUM_MOCK_BOOL2:action:_restart"  "${_CFGR_DISPATCH[0]}"
log_case "bool icon set"               "audio"                          "${_CFGR_ICONS[0]}"

section "cfgr::item::digit"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::digit --var VIBRANIUM_MOCK_INT --label "FPS" --title "FPS" --type int --min 15 --max 120
log_case "digit display"               "FPS : 42"                       "${_CFGR_ITEMS[0]}"
log_case "digit dispatch"              "digit:VIBRANIUM_MOCK_INT:FPS:FPS:int:15:120"  "${_CFGR_DISPATCH[0]}"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::digit --var VIBRANIUM_MOCK_INT --label "Volume" --title "Vol" --prompt "Enter vol" --type float
log_case "digit no range display"      "Volume : 42"                    "${_CFGR_ITEMS[0]}"
log_case "digit no range dispatch"     "digit:VIBRANIUM_MOCK_INT:Enter vol:Vol:float::"  "${_CFGR_DISPATCH[0]}"

section "cfgr::item::string"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::string --var VIBRANIUM_MOCK_STR --label "Codec" --title "Codec" \
  --option "H264:h264" "HEVC:hevc" "AV1:av1"
log_case "string display (reverse lookup)"  "Codec : H264"              "${_CFGR_ITEMS[0]}"

_expected="string:VIBRANIUM_MOCK_STR:Codec::H264:h264"$'\x1F'"HEVC:hevc"$'\x1F'"AV1:av1"
log_case "string dispatch"                  "$_expected"               "${_CFGR_DISPATCH[0]}"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::string --var VIBRANIUM_MOCK_STR --label "Codec" --title "Codec" --hook "_reload" \
  --option "H264:h264" "HEVC:hevc"
_expected="string:VIBRANIUM_MOCK_STR:Codec:_reload:H264:h264"$'\x1F'"HEVC:hevc"
log_case "string with hook"                "$_expected"               "${_CFGR_DISPATCH[0]}"

section "cfgr::item::action"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::action --func "_open_editor" --label "Edit config"
log_case "action display (bold)"       "<b>Edit config</b>"             "${_CFGR_ITEMS[0]}"
log_case "action dispatch"             "action:_open_editor"            "${_CFGR_DISPATCH[0]}"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::action --func "_sub" --label "Opacity : 0.9" --hook "pkill waybar"
log_case "action display (with :)"     "Opacity : 0.9"                  "${_CFGR_ITEMS[0]}"
log_case "action dispatch with hook"   "action:_sub"$'\x1E'"pkill waybar"  "${_CFGR_DISPATCH[0]}"

section "cfgr::item::raw"

_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()

cfgr::item::raw "Custom label : 42" "bool:VIBRANIUM_MOCK_BOOL" "my-icon"
log_case "raw display"               "Custom label : 42"                "${_CFGR_ITEMS[0]}"
log_case "raw dispatch"              "bool:VIBRANIUM_MOCK_BOOL"          "${_CFGR_DISPATCH[0]}"
log_case "raw icon"                  "my-icon"                          "${_CFGR_ICONS[0]}"

# Edge: nonexistent --var (no value in env)
_CFGR_ITEMS=()
_CFGR_DISPATCH=()
_CFGR_ICONS=()
cfgr::item::bool --var NONEXISTENT_VAR_XYZ --label "Ghost"
log_case "bool nonexistent var"      "Ghost : "                         "${_CFGR_ITEMS[0]}"

# =============================================================================
# 2. _cfgr::has_icons
# =============================================================================

section "_cfgr::has_icons"

_CFGR_ICONS=("" "" "")
_cfgr::has_icons; log_case "all empty"                    "1"    "$?"

_CFGR_ICONS=("" "icon" "")
_cfgr::has_icons; log_case "one non-empty"                "0"    "$?"

_CFGR_ICONS=("a" "b" "c")
_cfgr::has_icons; log_case "all non-empty"                "0"    "$?"

_CFGR_ICONS=()
_cfgr::has_icons; log_case "empty array"                  "1"    "$?"

# =============================================================================
# 3. cfgr::build_menu -- alignment, bool normalization, HTML stripping
# =============================================================================

section "cfgr::build_menu -- alignment"

cfgr::build_menu result "Short : val" "Longer label : val2"
log_case "short padded"              "Short        : val"              "${result[0]}"
log_case "longer unpadded"           "Longer label : val2"             "${result[1]}"

cfgr::build_menu result "A : 1" "B : 2"
log_case "equal r1"                  "A : 1"                           "${result[0]}"
log_case "equal r2"                  "B : 2"                           "${result[1]}"

cfgr::build_menu result "Only : item"
log_case "single item"              "Only : item"                     "${result[0]}"

cfgr::build_menu result
log_case "empty input"              ""                                "${result[*]}"

section "cfgr::build_menu -- bool normalization"

for v in true false TRUE FALSE True False; do
  cfgr::build_menu result "X : $v"
  case "${v,,}" in
    true)  exp="yes" ;;
    false) exp="no"  ;;
  esac
  log_case "'$v' -> '$exp'"          "X : $exp"                        "${result[0]}"
done
cfgr::build_menu result "X : maybe"
log_case "non-bool preserved"        "X : maybe"                       "${result[0]}"

section "cfgr::build_menu -- HTML tag stripping"

cfgr::build_menu result "<b>Short</b> : y" "Longer label : z"
log_case "tag padded"                "<b>Short</b>        : y"         "${result[0]}"
log_case "plain after tag"           "Longer label : z"                "${result[1]}"

cfgr::build_menu result "<span color='red'>Red</span> : hot"
log_case "span tag"                  "<span color='red'>Red</span> : hot"  "${result[0]}"

cfgr::build_menu result "<b>Bold</b> : y" "<i>Italic</i> : z"
log_case "both tags padded r1"       "<b>Bold</b>   : y"               "${result[0]}"
log_case "both tags padded r2"       "<i>Italic</i> : z"               "${result[1]}"

cfgr::build_menu result "<b>Only</b> : item"
log_case "single bold"               "<b>Only</b> : item"              "${result[0]}"

section "cfgr::build_menu -- non-matching lines"

cfgr::build_menu result "--- separator ---"
log_case "no colon delimiter"        "--- separator ---"               "${result[0]}"

cfgr::build_menu result "Real : option" "---" "Other : setting"
log_case "separator passthrough"     "---"                             "${result[1]}"
log_case "align before sep"          "Real  : option"                  "${result[0]}"
log_case "align after sep"           "Other : setting"                 "${result[2]}"

cfgr::build_menu result ": empty label"
log_case "empty label"               ": empty label"                   "${result[0]}"

cfgr::build_menu result "No value :"
log_case "no value"                  "No value :"                      "${result[0]}"

cfgr::build_menu result "<b>X</b> : 1" "A longer plain label : 2"
log_case "neg pad avoid r1"          "<b>X</b>                    : 1" "${result[0]}"
log_case "neg pad avoid r2"          "A longer plain label : 2"        "${result[1]}"

# =============================================================================
# 4. cfgr::toggle_bool
# =============================================================================

section "cfgr::toggle_bool"

_TDIR=$(mktemp -d /tmp/vb_test_toggle.XXXXXX)
_TSET="$_TDIR/settings"
echo 'VIBRANIUM_TG=true' > "$_TSET"
_TSAVE="$VIBRANIUM_USER_SETTINGS"
export VIBRANIUM_USER_SETTINGS="$_TSET"
source "$_TSET"

cfgr::toggle_bool VIBRANIUM_TG
source "$_TSET"
log_case "true -> false"            "false"                            "$VIBRANIUM_TG"

cfgr::toggle_bool VIBRANIUM_TG
source "$_TSET"
log_case "false -> true"            "true"                             "$VIBRANIUM_TG"

output=$(cfgr::toggle_bool --print VIBRANIUM_TG 2>/dev/null)
source "$_TSET"
log_case "--print outputs new val"  "false"                            "$output"

cfgr::toggle_bool -p VIBRANIUM_TG >/dev/null 2>&1
source "$_TSET"
log_case "-p toggles correctly"     "true"                             "$VIBRANIUM_TG"

export VIBRANIUM_USER_SETTINGS="$_TSAVE"
rm -rf "$_TDIR"
unset _TDIR _TSET _TSAVE

# =============================================================================
# 5. _cfgr::verify_option
# =============================================================================

section "_cfgr::verify_option"

_cfgr::verify_option "VIBRANIUM_MOCK_BOOL"; log_case "var in settings -> rc 0" "0" "$?"
_cfgr::verify_option "NOT_IN_SETTINGS";     log_case "not in defaults"        "1" "$?"
_cfgr::verify_option "";                    log_case "empty var -> rc 2"       "2" "$?"

# =============================================================================
# 6. cfgr::dispatch -- types that do NOT call rofi
# =============================================================================

section "cfgr::dispatch -- bool"

_TDIR=$(mktemp -d /tmp/vb_test_dis.XXXXXX)
_TSET="$_TDIR/settings"
echo 'VIBRANIUM_DB=true' > "$_TSET"
_TSAVE="$VIBRANIUM_USER_SETTINGS"
export VIBRANIUM_USER_SETTINGS="$_TSET"
source "$_TSET"

cfgr::dispatch "bool:VIBRANIUM_DB"
source "$_TSET"
log_case "bool toggle"              "false"                              "$VIBRANIUM_DB"

_hook_fired=false
_hook_fn() { _hook_fired=true; }
echo 'VIBRANIUM_DB2=false' > "$_TSET"
source "$_TSET"
cfgr::dispatch "bool:VIBRANIUM_DB2:action:_hook_fn"
source "$_TSET"
log_case "bool toggle with hook"    "true"                               "$VIBRANIUM_DB2"
log_case "bool hook fired"          "true"                               "$_hook_fired"

export VIBRANIUM_USER_SETTINGS="$_TSAVE"
rm -rf "$_TDIR"
unset _TDIR _TSET _TSAVE _hook_fired _hook_fn

section "cfgr::dispatch -- display (no-op)"

cfgr::dispatch "display:"
log_case "display no-op"            "0"                                  "$?"

section "cfgr::dispatch -- action (function)"

_fn_called=false
_fn() { _fn_called=true; }
cfgr::dispatch "action:_fn"
log_case "action calls function"    "true"                               "$_fn_called"

cfgr::dispatch "action:_fn"
log_case "action calls function again" "true"                            "$_fn_called"

section "cfgr::dispatch -- action (compound command)"

_result=""
cfgr::dispatch "action:_result='hello world'"
log_case "compound command"         "hello world"                        "$_result"

# =============================================================================
# 7. Edge cases
# =============================================================================

section "edge cases"

cfgr::dispatch "" 2>/dev/null
log_case "empty descriptor"         "0"                                  "$?"

cfgr::dispatch "unknown:foo" 2>/dev/null
log_case "unknown type"             "0"                                  "$?"

cfgr::dispatch "action:_nonexistent_fn_xyz123" 2>/dev/null
log_case "unknown function"         "1"                                  "$?"

summary
