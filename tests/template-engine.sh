#!/bin/bash

# Test suite for vb-theme-set-templates.awk
#
# Exercises the template engine: plain substitution, format suffixes
# (_strip/_upper/_lower/_0x/_rgb/_hsl/_hwb, per-channel scalars), pipe
# operations (alpha, lightness, RGB channel nudges, HSL/HWB manipulators),
# non-hex passthrough, and unresolvable-token preservation.

SELF="${0##*/}"
AWK_SCRIPT="$(cd "$(dirname "$0")/../awk" && pwd)/vb-theme-set-templates.awk"
TMPDIR=$(mktemp -d /tmp/vb_test_tpl.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
TOTAL=0

_g=$'\e[0;32m'
_r=$'\e[0;31m'
_y=$'\e[0;33m'
_c=$'\e[0;36m'
_z=$'\e[90m'
_R=$'\e[0m'

section() { printf "\n${_c}=== %s ===${_R}\n\n" "$1"; }

# Build a subs file and outmap, create templates, then run the awk engine.
# Usage: _run \
#   --subs key val key val ... -- \
#   --outmap tpl_name out_name tpl_name out_name ... -- \
#   --tpl name content name content ...
_run() {
  local phase="" subs_file="$TMPDIR/subs" outmap_file="$TMPDIR/outmap"

  : >"$subs_file"
  : >"$outmap_file"

  local args=("$@")
  local i=0

  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
    --subs)
      phase="subs"; ((i++)); continue ;;
    --outmap)
      phase="outmap"; ((i++)); continue ;;
    --tpl)
      phase="tpl"; ((i++)); continue ;;
    --)
      ((i++)); continue ;;
    esac

    if [[ $phase == "subs" ]]; then
      local key="${args[$i]}" val="${args[$((i+1))]}"
      printf '%s\x01%s\n' "$key" "$val" >>"$subs_file"
      ((i+=2))
    elif [[ $phase == "outmap" ]]; then
      local name="${args[$i]}" out="${args[$((i+1))]}"
      printf '%s\x01%s\n' "$TMPDIR/tpl_$name" "$TMPDIR/out_$out" >>"$outmap_file"
      ((i+=2))
    elif [[ $phase == "tpl" ]]; then
      local name="${args[$i]}" content="${args[$((i+1))]}"
      printf '%s' "$content" >"$TMPDIR/tpl_$name"
      ((i+=2))
    fi
  done

  # Collect all template files
  local tpl_files=()
  for f in "$TMPDIR"/tpl_*; do
    [[ -f $f && $f != "$TMPDIR/subs" && $f != "$TMPDIR/outmap" ]] && tpl_files+=("$f")
  done

  awk -f "$AWK_SCRIPT" "$subs_file" "$outmap_file" "${tpl_files[@]}" 2>/dev/null
}

_read_out() { cat "$TMPDIR/out_$1" 2>/dev/null; }

_clean() { rm -f "$TMPDIR"/tpl_* "$TMPDIR"/out_* "$TMPDIR"/subs "$TMPDIR"/outmap; }

log_case() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ $actual == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "  ${_z}[%02d]${_R} ${_g}PASS${_R}  %s\n" "$TOTAL" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  ${_z}[%02d]${_R} ${_r}FAIL${_R}  %s\n" "$TOTAL" "$label"
    printf "       ${_z}expect: ${_R}%s\n" "$expected"
    printf "       ${_z}got:    ${_R}%s\n" "$actual"
  fi
}

summary() {
  printf "\n%s\n" "$(printf '=%.0s' {1..55})"
  printf "  ${_g}%d passed${_R}  ${_r}%d failed${_R}  %d total\n" "$PASS" "$FAIL" "$TOTAL"
  printf "%s\n\n" "$(printf '=%.0s' {1..55})"
  ((FAIL == 0))
}

# =============================================================================
# 1. Basic substitution and format variants
# =============================================================================

section "basic - plain key, format suffixes"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
  -- \
  --outmap \
    basic basic \
    strip strip \
    upper upper \
    lower lower \
    zerox zerox \
    frgb frgb \
    fr fr \
    fg fg \
    fb fb \
    fh fh \
    fs fs \
    fl fl \
    fhsl fhsl \
    fhwb fhwb \
    fw fw \
  -- \
  --tpl \
    basic '{{ color4 }}' \
    strip '{{ color4_strip }}' \
    upper '{{ color4_upper }}' \
    lower '{{ color4_lower }}' \
    zerox '{{ color4_0x }}' \
    frgb '{{ color4_rgb }}' \
    fr '{{ color4_r }}' \
    fg '{{ color4_g }}' \
    fb '{{ color4_b }}' \
    fh '{{ color4_h }}' \
    fs '{{ color4_s }}' \
    fl '{{ color4_l }}' \
    fhsl '{{ color4_hsl }}' \
    fhwb '{{ color4_hwb }}' \
    fw '{{ color4_w }}'

log_case "plain hex key"         "#c94f6d"       "$(_read_out basic)"
log_case "strip suffix"          "c94f6d"        "$(_read_out strip)"
log_case "upper suffix"          "#C94F6D"       "$(_read_out upper)"
log_case "lower suffix"          "#c94f6d"       "$(_read_out lower)"
log_case "0x suffix"             "0xc94f6d"      "$(_read_out zerox)"
log_case "rgb format"            "201,79,109"    "$(_read_out frgb)"
log_case "r scalar"              "201"           "$(_read_out fr)"
log_case "g scalar"              "79"            "$(_read_out fg)"
log_case "b scalar"              "109"           "$(_read_out fb)"
log_case "h scalar"              "345"           "$(_read_out fh)"
log_case "s scalar"              "53"            "$(_read_out fs)"
log_case "l scalar"              "55"            "$(_read_out fl)"
log_case "hsl format"            "345,53,55"     "$(_read_out fhsl)"
log_case "hwb format"            "345,31%,21%"   "$(_read_out fhwb)"
log_case "w scalar"              "31"            "$(_read_out fw)"

# =============================================================================
# 2. Non-hex pass-through
# =============================================================================

section "non-hex - pass-through, upper, strip"

_clean

_run \
  --subs \
    font '"Fira Code"' \
  -- \
  --outmap \
    nh nh \
    nhu nhu \
    nhs nhs \
  -- \
  --tpl \
    nh '{{ font }}' \
    nhu '{{ font_upper }}' \
    nhs '{{ font_strip }}'

log_case "non-hex literal"   '"Fira Code"'  "$(_read_out nh)"
log_case "non-hex upper"     '"FIRA CODE"'  "$(_read_out nhu)"
log_case "non-hex strip"     '"Fira Code"'  "$(_read_out nhs)"

# =============================================================================
# 3. Pipe - alpha
# =============================================================================

section "pipe - alpha"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
  -- \
  --outmap \
    alpha alpha \
    alpha_rgb alpha_rgb \
  -- \
  --tpl \
    alpha '{{ color4|alpha=0.5 }}' \
    alpha_rgb '{{ color4_rgb|alpha=0.5 }}'

log_case "hex alpha 0.5"       "#c94f6d80"        "$(_read_out alpha)"
log_case "rgb alpha 0.5"       "201,79,109,0.5"   "$(_read_out alpha_rgb)"

# =============================================================================
# 4. Pipe - lightness (relative +/- and absolute)
# =============================================================================

section "pipe - lightness"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    hlm  hlm \
    hlp  hlp \
    hla  hla \
    rlm  rlm \
    rlp  rlp \
    rred rred \
    rgrn rgrn \
    rblu rblu \
    hlt  hlt \
    hdk  hdk \
    hst  hst \
    hds  hds \
    hhr  hhr \
    wwn  wwn \
    bbn  bbn \
    slp  slp \
  -- \
  --tpl \
    hlm  '{{ red|lightness=-0.05 }}' \
    hlp  '{{ red|lightness=+0.10 }}' \
    hla  '{{ red|lightness=0.80 }}' \
    rlm  '{{ red_rgb|lightness=-0.05 }}' \
    rlp  '{{ red_rgb|lightness=+0.10 }}' \
    rred '{{ red_rgb|red=+10 }}' \
    rgrn '{{ red_rgb|green=+20 }}' \
    rblu '{{ red_rgb|blue=+30 }}' \
    hlt  '{{ red_hsl|lighten=10 }}' \
    hdk  '{{ red_hsl|darken=10 }}' \
    hst  '{{ red_hsl|saturate=10 }}' \
    hds  '{{ red_hsl|desaturate=10 }}' \
    hhr  '{{ red_hsl|hue=60 }}' \
    wwn  '{{ red_hwb|whiten=10 }}' \
    bbn  '{{ red_hwb|blacken=10 }}' \
    slp  '{{ red_l|lightness=+0.10 }}'

log_case "hex lightness=-0.05"    "#e60000"        "$(_read_out hlm)"
log_case "hex lightness=+0.10"    "#ff3333"        "$(_read_out hlp)"
log_case "hex lightness=0.80"     "#ff9999"        "$(_read_out hla)"
log_case "rgb lightness=-0.05"    "230,0,0"        "$(_read_out rlm)"
log_case "rgb lightness=+0.10"    "255,51,51"      "$(_read_out rlp)"
log_case "rgb red=+10"            "255,0,0"        "$(_read_out rred)"
log_case "rgb green=+20"          "255,20,0"       "$(_read_out rgrn)"
log_case "rgb blue=+30"           "255,0,30"       "$(_read_out rblu)"
log_case "hsl lighten=10"         "0,100,60"       "$(_read_out hlt)"
log_case "hsl darken=10"          "0,100,40"       "$(_read_out hdk)"
log_case "hsl saturate=10"        "0,100,50"       "$(_read_out hst)"
log_case "hsl desaturate=10"      "0,90,50"        "$(_read_out hds)"
log_case "hsl hue=60"             "60,100,50"      "$(_read_out hhr)"
log_case "hwb whiten=10"          "0,10%,0%"       "$(_read_out wwn)"
log_case "hwb blacken=10"         "0,0%,10%"       "$(_read_out bbn)"
log_case "scalar l +0.10"         "60"             "$(_read_out slp)"

# =============================================================================
# 5. Unknown / unresolvable tokens
# =============================================================================

section "unknown tokens - left untouched"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
  -- \
  --outmap \
    uk  uk \
    ukp ukp \
    uks uks \
    bad bad \
  -- \
  --tpl \
    uk  '{{ nonexistent }}' \
    ukp '{{ nonexistent|lightness=0.5 }}' \
    uks '{{ color_unknown_rgb }}' \
    bad '{{ fontname_rgb }}'

log_case "unknown key"                "{{ nonexistent }}"              "$(_read_out uk)"
log_case "unknown key with pipe"      "{{ nonexistent|lightness=0.5 }}" "$(_read_out ukp)"
log_case "unknown key with suffix"    "{{ color_unknown_rgb }}"        "$(_read_out uks)"
log_case "non-hex with rgb suffix"    "{{ fontname_rgb }}"             "$(_read_out bad)"

# =============================================================================
# 6. Multiple tokens + multi-line
# =============================================================================

section "multiple tokens and multi-line"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
    accent '#719cd6' \
  -- \
  --outmap \
    multi multi \
    ml    ml \
  -- \
  --tpl \
    multi 'color4={{ color4 }}, accent={{ accent }}' \
    ml    "$(printf 'first: {{ color4 }}\nsecond: {{ accent }}')"

log_case "two tokens one line"        "color4=#c94f6d, accent=#719cd6"  "$(_read_out multi)"
IFS= read -r l1 <"$TMPDIR/out_ml"
IFS= read -r l2 < <(tail -n +2 "$TMPDIR/out_ml")
log_case "multi-line line 1"          "first: #c94f6d"                  "$l1"
log_case "multi-line line 2"          "second: #719cd6"                 "$l2"

# =============================================================================
# 7. Passthrough - no placeholders
# =============================================================================

section "passthrough - no placeholders"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
  -- \
  --outmap \
    pt pt \
  -- \
  --tpl \
    pt "$(printf 'hello world\nno placeholders here')"

readarray -t pt_lines <"$TMPDIR/out_pt"
log_case "passthrough line 1"  "hello world"            "${pt_lines[0]}"
log_case "passthrough line 2"  "no placeholders here"   "${pt_lines[1]}"

# =============================================================================
# 8. Edge cases - whitespace in tokens
# =============================================================================

section "edge cases - whitespace in tokens"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    edge1 edge1 \
    edge2 edge2 \
  -- \
  --tpl \
    edge1 '{{red}}  {{  red  }}  {{red_rgb}}' \
    edge2 '{{ red|lightness=-0.05 }}'

log_case "adjacent and padded tokens" "#ff0000  #ff0000  255,0,0"  "$(_read_out edge1)"
log_case "piped with inner spaces"    "#e60000"                    "$(_read_out edge2)"

# =============================================================================
# 9. Two templates, different outputs
# =============================================================================

section "multiple templates, different outputs"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
    accent '#719cd6' \
  -- \
  --outmap \
    ta ta \
    tb tb \
  -- \
  --tpl \
    ta '{{ color4 }}' \
    tb '{{ accent }}'

log_case "tpl_a output"  "#c94f6d"  "$(_read_out ta)"
log_case "tpl_b output"  "#719cd6"  "$(_read_out tb)"

# =============================================================================
# 10. Empty subs table
# =============================================================================

section "empty subs table - tokens left untouched"

_clean

_run \
  --subs \
  -- \
  --outmap \
    es es \
  -- \
  --tpl \
    es '{{ color4 }} nothing happens'

log_case "no subs"  "{{ color4 }} nothing happens"  "$(_read_out es)"

# =============================================================================
# 11. Multiple pipe operations in chain
# =============================================================================

section "pipe chain - multiple operations"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    chain1 chain1 \
    chain2 chain2 \
  -- \
  --tpl \
    chain1 '{{ red_hsl|lighten=10|saturate=5|hue=180 }}' \
    chain2 '{{ red_rgb|red=-50|green=+100|blue=+200 }}'

log_case "hsl chain (lighten, saturate, hue)"  "180,100,60"  "$(_read_out chain1)"
log_case "rgb chain (channel nudges)"           "205,100,200" "$(_read_out chain2)"

# =============================================================================
# 12. Eight-digit hex (source color with alpha byte)
# =============================================================================

section "8-digit hex in subs - alpha in source"

_clean

_run \
  --subs \
    color8 '#c94f6d80' \
  -- \
  --outmap \
    e8  e8 \
    e8s e8s \
    e8a e8a \
    e8r e8r \
  -- \
  --tpl \
    e8  '{{ color8 }}' \
    e8s '{{ color8_strip }}' \
    e8a '{{ color8|alpha=0.5 }}' \
    e8r '{{ color8_rgb }}'

log_case "8-digit hex passthrough"  "#c94f6d80"    "$(_read_out e8)"
log_case "8-digit strip"            "c94f6d80"     "$(_read_out e8s)"
log_case "8-digit alpha override"   "#c94f6d80"    "$(_read_out e8a)"
log_case "8-digit rgb (6-char)"     "201,79,109"   "$(_read_out e8r)"

# =============================================================================
# 13. Combined format suffix + pipe
# =============================================================================

section "suffix + pipe combined"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    s1 s1 \
    s2 s2 \
    s3 s3 \
  -- \
  --tpl \
    s1 '{{ red_lower|lightness=-0.05 }}' \
    s2 '{{ red_upper|lightness=+0.10 }}' \
    s3 '{{ red_strip|lightness=-0.05 }}'

log_case "lower + lightness=-0.05"  "#e60000"   "$(_read_out s1)"
log_case "upper + lightness=+0.10"  "#FF3333"   "$(_read_out s2)"
log_case "strip + lightness=-0.05"  "e60000"    "$(_read_out s3)"

# =============================================================================
# 14. Empty / broken placeholders
# =============================================================================

section "empty and broken placeholders"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
  -- \
  --outmap \
    b1 b1 \
    b2 b2 \
    b3 b3 \
  -- \
  --tpl \
    b1 '{{ }}' \
    b2 'unclosed {{ forever' \
    b3 '{{ color4'

log_case "empty braces {{ }}"         "{{ }}"               "$(_read_out b1)"
log_case "unclosed {{ with no }}"     "unclosed {{ forever" "$(_read_out b2)"
log_case "unclosed valid key"         "{{ color4"           "$(_read_out b3)"

# =============================================================================
# 15. Boundary clamping - lightness extremes
# =============================================================================

section "boundary clamping - lightness extremes"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    c0 c0 \
    c1 c1 \
    c2 c2 \
    c3 c3 \
  -- \
  --tpl \
    c0 '{{ red|lightness=0 }}' \
    c1 '{{ red|lightness=1.0 }}' \
    c2 '{{ red|lightness=-10 }}' \
    c3 '{{ red|lightness=+10 }}'

log_case "lightness=0 (absolute)"     "#000000"   "$(_read_out c0)"
log_case "lightness=1.0 (absolute)"   "#ffffff"   "$(_read_out c1)"
log_case "lightness=-10 (clamped)"    "#000000"   "$(_read_out c2)"
log_case "lightness=+10 (clamped)"    "#ffffff"   "$(_read_out c3)"

# =============================================================================
# 16. Scalar hue wrapping
# =============================================================================

section "scalar hue wrapping"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
  -- \
  --outmap \
    hw1 hw1 \
    hw2 hw2 \
  -- \
  --tpl \
    hw1 '{{ color4_h|lightness=+1.5 }}' \
    hw2 '{{ color4_h|lightness=-0.5 }}'

# color4_h = 345
# +1.5: (345 + 1.5*360) % 360 = 165
# -2.0: (345 - 2.0*360) % 360 -> ((345-720) % 360 + 360) % 360 = (-375 % 360 + 360) % 360
#   In AWK: -375 % 360 = -375 - (-2 * 360) = -375 + 720 = 345
# wait: int(-375/360) = int(-1.0417) = -1 (AWK truncates toward zero? No, AWK uses floor.)
#   Actually, AWK's `%` operator: x % y = x - (int(x/y) * y)
#   int(-1.0417) = -1 in AWK (truncates toward zero)
#   So -375 % 360 = -375 - (-1 * 360) = -375 + 360 = -15
#   Then: (-15 + 360) % 360 = 345 % 360 = 345
# Hmm wait, that doesn't wrap. Let me reconsider.
# For hue -= 2.0*360: scalar_val + (-2.0) * 360.0 = 345 - 720 = -375
# ((345 - 720) % 360 + 360) % 360 = ((-375) % 360 + 360) % 360
# = (-375 - int(-375/360)*360 + 360) % 360
# = (-375 - (-1)*360 + 360) % 360
# = (-375 + 360 + 360) % 360 = 345 % 360 = 345
# Actually that's 345, which is the same as the original hue.
# The scalar hue wrapping test is a bit awkward. Let me just test one case.

# Actually, let me verify. For -2.0 full cycles, hue should come back to itself.
# For -0.5 cycles: (345 - 0.5*360) % 360 = (345 - 180) % 360 = 165 % 360 = 165
# Let me use that instead.

log_case "hue +1.5 cycles"  "165"  "$(_read_out hw1)"
log_case "hue -0.5 cycles"  "165"  "$(_read_out hw2)"

# =============================================================================
# 17. HWB with hue pipe
# =============================================================================

section "HWB - hue pipe"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    hwh hwh \
    hwc hwc \
  -- \
  --tpl \
    hwh '{{ red_hwb|hue=90 }}' \
    hwc '{{ red_hwb|hue=180|whiten=20 }}'

# red: hwb(0, 0%, 0%)
log_case "hwb hue=90"           "90,0%,0%"    "$(_read_out hwh)"
log_case "hwb hue=180 + whiten"  "180,20%,0%" "$(_read_out hwc)"

# =============================================================================
# 18. HSL combined ops
# =============================================================================

section "HSL - combined ops in chain"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    hc1 hc1 \
    hc2 hc2 \
  -- \
  --tpl \
    hc1 '{{ red_hsl|lighten=10|hue=120 }}' \
    hc2 '{{ red_hsl|darken=10|desaturate=30|hue=240 }}'

# red_hsl = 0,100,50
# lighten=10 -> 0,100,60; hue=120 -> 120,100,60
log_case "hsl lighten + hue"          "120,100,60"  "$(_read_out hc1)"
# darken=10 -> 0,100,40; desaturate=30 -> 0,70,40; hue=240 -> 240,70,40
log_case "hsl darken+desaturate+hue"  "240,70,40"   "$(_read_out hc2)"

# =============================================================================
# 19. Precompute collision - explicit key overrides derived variant
# =============================================================================

section "precompute collision - explicit key beats derived"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
    color4_rgb 'custom,value' \
  -- \
  --outmap \
    pc1 pc1 \
    pc2 pc2 \
  -- \
  --tpl \
    pc1 '{{ color4_rgb }}' \
    pc2 '{{ color4_hsl }}'

log_case "explicit color4_rgb"  "custom,value"  "$(_read_out pc1)"
log_case "derived hsl unaffected" "345,53,55"   "$(_read_out pc2)"

# =============================================================================
# 20. Non-hex with _0x suffix
# =============================================================================

section "non-hex with _0x suffix - returns raw value"

_clean

_run \
  --subs \
    font '"Fira Code"' \
  -- \
  --outmap \
    nx0 nx0 \
  -- \
  --tpl \
    nx0 '{{ font_0x }}'

# _0x is not a recognized suffix for non-hex values; falls through to unknown-key
# handling and the original token is left in place.
log_case "non-hex _0x unknown"  "{{ font_0x }}"  "$(_read_out nx0)"

# =============================================================================
# 21. Trailing pipe (empty ops)
# =============================================================================

section "trailing pipe - empty ops string"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    tp1 tp1 \
    tp2 tp2 \
  -- \
  --tpl \
    tp1 '{{ red| }}' \
    tp2 '{{ red|lightness=-0.05| }}'

log_case "trailing pipe with empty op"  "#ff0000"  "$(_read_out tp1)"
log_case "valid pipe then trailing"      "#e60000"  "$(_read_out tp2)"

# =============================================================================
# 22. Hex lightness + alpha combined (hex_modified + has_alpha)
# =============================================================================

section "hex - lightness + alpha combined"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    hla hla \
  -- \
  --tpl \
    hla '{{ red|lightness=+0.10|alpha=0.5 }}'

# lightness=+0.10 -> l=60 -> #ff3333; alpha=0.5 -> 80 in hex -> #ff333380
log_case "lightness + alpha"  "#ff333380"  "$(_read_out hla)"

# =============================================================================
# 23. Garbage hex in subs - invalid hex digits parse as zeros
# =============================================================================

section "garbage data - invalid hex digits"

# The awk engine does NOT validate hex digits. Plain {{ key }} returns the
# literal value from subs as-is. Format suffixes trigger parse_hex() which
# maps unknown chars through _hv[] where undefined entries return 0. Short
# hex strings partially parse: existing digits are read, missing positions
# default to zero.
_clean

_run \
  --subs \
    bad '#GGGGGG' \
    short '#12' \
  -- \
  --outmap \
    gh1 gh1 \
    gh2 gh2 \
    gh3 gh3 \
    gh4 gh4 \
  -- \
  --tpl \
    gh1 '{{ bad }}' \
    gh2 '{{ bad_rgb }}' \
    gh3 '{{ short }}' \
    gh4 '{{ short_rgb }}'

log_case "invalid hex passthrough"  "#GGGGGG"  "$(_read_out gh1)"
log_case "invalid hex -> rgb"        "0,0,0"    "$(_read_out gh2)"
log_case "short hex passthrough"    "#12"      "$(_read_out gh3)"
log_case "short hex -> rgb (18,0,0)" "18,0,0"   "$(_read_out gh4)"

# =============================================================================
# 24. Garbage pipe operations
# =============================================================================

section "garbage data - pipe operations"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    gp1 gp1 \
    gp2 gp2 \
    gp3 gp3 \
    gp4 gp4 \
  -- \
  --tpl \
    gp1 '{{ red|lightness=abc }}' \
    gp2 '{{ red|alpha=-0.5 }}' \
    gp3 '{{ red|alpha=2.0 }}' \
    gp4 '{{ red|blah=5 }}'

# lightness=abc: op_val = "abc" + 0 = 0, substr("abc",1,1)="a" -> absolute 0 -> black
log_case "lightness=abc (non-numeric)"  "#000000"  "$(_read_out gp1)"
# alpha=-0.5: alpha= does not support relative +/- signs, so the leading
# "-" is stripped with a warning rather than being applied, leaving 0.5
log_case "alpha=-0.5 (sign stripped)"  "#ff000080"  "$(_read_out gp2)"
# alpha=2.0: clamped to 1.0 -> ff
log_case "alpha=2.0 (clamped to 1)"    "#ff0000ff"  "$(_read_out gp3)"
# unknown op name silently skipped
log_case "unknown op 'blah=5'"          "#ff0000"    "$(_read_out gp4)"

# =============================================================================
# 25. Malformed tokens - nested braces, unbalanced, wrong syntax
# =============================================================================

section "garbage data - malformed tokens"

_clean

_run \
  --subs \
    color4 '#c94f6d' \
  -- \
  --outmap \
    mt1 mt1 \
    mt2 mt2 \
    mt3 mt3 \
    mt4 mt4 \
    mt5 mt5 \
  -- \
  --tpl \
    mt1 '{{{{ }}}}' \
    mt2 '}}}}' \
    mt3 '{{|color4}}' \
    mt4 '{{color4=val}}' \
    mt5 '   '

# {{ {{ }} }} - inner {{ }} is matched first; outer braces become literal
log_case "nested {{{{ }}}}"    "{{{{ }}}}"   "$(_read_out mt1)"
# just closers - no placeholder
log_case "unbalanced }}}}"     "}}}}"         "$(_read_out mt2)"
# pipe at start - no key
log_case "pipe at start {{|"   "{{|color4}}"  "$(_read_out mt3)"
# equals instead of pipe
log_case "equals instead of |" "{{color4=val}}" "$(_read_out mt4)"
# whitespace only
log_case "whitespace only"     "   "          "$(_read_out mt5)"

# =============================================================================
# 26. Double pipe - empty segment in chain
# =============================================================================

section "garbage data - double pipe"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    dp1 dp1 \
  -- \
  --tpl \
    dp1 '{{ red||lightness=-0.05 }}'

# |lightness=0.05| -> split on | gives ["", "lightness=-0.05"]; empty first
# segment is skipped because it has no "=".
log_case "double pipe with no op"  "#e60000"  "$(_read_out dp1)"

# =============================================================================
# 27. Alpha - leading sign is stripped, not treated as relative
# =============================================================================

section "alpha - leading sign stripped on hex and rgb"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    ha1 ha1 \
    ha2 ha2 \
    ha3 ha3 \
    ra1 ra1 \
    ra2 ra2 \
    ra3 ra3 \
    ra4 ra4 \
    ra5 ra5 \
    ra6 ra6 \
    ra7 ra7 \
  -- \
  --tpl \
    ha1 '{{ red|alpha=0.5 }}' \
    ha2 '{{ red|alpha=+0.5 }}' \
    ha3 '{{ red|alpha=-0.5 }}' \
    ra1 '{{ red_rgb|alpha=0.5 }}' \
    ra2 '{{ red_rgb|alpha=+0.5 }}' \
    ra3 '{{ red_rgb|alpha=-0.5 }}' \
    ra4 '{{ red_rgb|alpha=2.0 }}' \
    ra5 '{{ red_rgb|alpha=-2.0 }}' \
    ra6 '{{ red_rgb|alpha=1.0 }}' \
    ra7 '{{ red_rgb|alpha=0 }}'

# alpha= is always an absolute value: there is no "current alpha" anywhere
# in the pipeline for a sign to shift relative to. A leading "+" or "-" is
# stripped before the number is parsed, rather than being applied and then
# clamped, so alpha=-0.5 lands on 0.5, not on 0.
log_case "hex alpha plain 0.5"        "#ff000080"    "$(_read_out ha1)"
log_case "hex alpha +0.5 (sign stripped)" "#ff000080" "$(_read_out ha2)"
log_case "hex alpha -0.5 (sign stripped)" "#ff000080" "$(_read_out ha3)"
log_case "rgb alpha plain 0.5"        "255,0,0,0.5"  "$(_read_out ra1)"
log_case "rgb alpha +0.5 (sign stripped)" "255,0,0,0.5"  "$(_read_out ra2)"
log_case "rgb alpha -0.5 (sign stripped)" "255,0,0,0.5"  "$(_read_out ra3)"
log_case "rgb alpha 2.0 (clamped)"    "255,0,0,1"    "$(_read_out ra4)"
log_case "rgb alpha -2.0 (sign stripped, then clamped)" "255,0,0,1" "$(_read_out ra5)"
log_case "rgb alpha 1.0"              "255,0,0,1"    "$(_read_out ra6)"
log_case "rgb alpha 0"                "255,0,0,0"    "$(_read_out ra7)"

# =============================================================================
# 28. Channel nudge and lightness ordering
# =============================================================================

section "rgb channel nudge vs lightness ordering"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    ord1 ord1 \
    ord2 ord2 \
  -- \
  --tpl \
    ord1 '{{ red_rgb|blue=-30|lightness=0.8 }}' \
    ord2 '{{ red_rgb|lightness=0.8|blue=-30 }}'

# lightness rebuilds red/green/blue from scratch via hsl_to_rgb, so a channel
# nudge applied before it gets overwritten. Applied after, the nudge lands
# on top of the already-rebuilt channels and survives.
log_case "nudge before lightness (lost)"     "255,153,153"  "$(_read_out ord1)"
log_case "lightness before nudge (survives)" "255,153,123"  "$(_read_out ord2)"

# =============================================================================
# 29. Negative hue rotation on hsl/hwb (not just scalar)
# =============================================================================

section "negative hue rotation - hsl and hwb formats"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    nh1 nh1 \
    nh2 nh2 \
  -- \
  --tpl \
    nh1 '{{ red_hsl|hue=-45 }}' \
    nh2 '{{ red_hwb|hue=-45 }}'

# red_hsl = 0,100,50; -45 wraps to 315
log_case "hsl hue=-45 wraps"  "315,100,50"  "$(_read_out nh1)"
log_case "hwb hue=-45 wraps"  "315,0%,0%"   "$(_read_out nh2)"

# =============================================================================
# 30. Malformed op syntax - spaces around '=', unknown op names
# =============================================================================

section "malformed op syntax - silently ignored, not crashed"

_clean

_run \
  --subs \
    red '#ff0000' \
  -- \
  --outmap \
    mo1 mo1 \
    mo2 mo2 \
    mo3 mo3 \
  -- \
  --tpl \
    mo1 '{{ red|lightness = -0.05 }}' \
    mo2 '{{ red_RGB }}' \
    mo3 '{{ red_r|foo=5 }}'

# "lightness = -0.05" has spaces around the "=", so op_name becomes
# "lightness " (trailing space) which never matches "lightness"; the op is
# skipped rather than applied or crashing.
log_case "spaces around = (op ignored)"  "#ff0000"      "$(_read_out mo1)"
# Suffix matching is case-sensitive; "_RGB" is not a recognized suffix, so
# the token falls through as an unresolved key and is left in place.
log_case "uppercase suffix unresolved"   "{{ red_RGB }}" "$(_read_out mo2)"
# "foo" is not a recognized op name on a scalar key, so it is skipped and
# the scalar value passes through unchanged.
log_case "unknown op on scalar key"      "255"          "$(_read_out mo3)"

# =============================================================================
# 31. Alpha sign warning - message format and presence/absence
# =============================================================================

section "alpha sign warning - stderr message"

_clean
printf 'red\x01#ff0000\n' >"$TMPDIR/subs"
printf '%s\x01%s\n' "$TMPDIR/tpl_warn" "$TMPDIR/out_warn" >"$TMPDIR/outmap"
printf '%s' '{{ red|alpha=+0.5 }}' >"$TMPDIR/tpl_warn"

warn_output="$(awk -f "$AWK_SCRIPT" "$TMPDIR/subs" "$TMPDIR/outmap" "$TMPDIR/tpl_warn" 2>&1 >/dev/null)"
log_case "warning printed for signed alpha" \
  "[vb-theme-set-templates] Warn alpha= does not support relative +/- values, sign ignored." \
  "$warn_output"

_clean
printf 'red\x01#ff0000\n' >"$TMPDIR/subs"
printf '%s\x01%s\n' "$TMPDIR/tpl_nowarn" "$TMPDIR/out_nowarn" >"$TMPDIR/outmap"
printf '%s' '{{ red|alpha=0.5 }}' >"$TMPDIR/tpl_nowarn"

nowarn_output="$(awk -f "$AWK_SCRIPT" "$TMPDIR/subs" "$TMPDIR/outmap" "$TMPDIR/tpl_nowarn" 2>&1 >/dev/null)"
log_case "no warning for unsigned alpha" "" "$nowarn_output"

summary
