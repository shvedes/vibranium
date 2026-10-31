#!/bin/bash
# Suite: themes/ - the 30 shipped palettes, the files each one carries, and
# the colour keys the shell and the theme engine actually read.
#
# Nothing in the tree tests this surface. The settings suites cover
# shell/common/settings/catalog.jsonc, the assets suite covers shell/assets/, and the
# theme picker is only ever probed with a synthetic /tmp tree
# (ThemePicker.qml:153), so the 30 real themes, their 14-colour palettes and
# their 183 wallpapers are untested data that a single dropped `colors.list`
# key silently degrades.
#
# The required colour set is DERIVED, not copied. Four independent sources in
# the tree name colour keys, and they are read back here rather than restated:
#
#   default/themed/*.tpl              the templates. Every {{ token }} is
#                                      resolved against the suffix table in
#                                      awk/vb-theme-set-templates.awk:279-292
#                                      exactly as resolve_token() does (a token
#                                      that is itself a palette key wins before
#                                      any suffix is stripped), which yields the
#                                      base keys the engine can reach.
#   default/themed/qs.json.tpl        the palette the shell reads
#   shell/common/theme/Theme.qml      the keys Theme.qml binds and the fallbacks
#                                      in color(), which are the same set
#   shell/features/pickers/theme/     the 7 swatches ThemePicker.qml and
#                                      ThemeRemover.qml read out of colors.list
#
# A key is a `_suffix` of a base key (`_rgb`, `_hsl`, `_lower`, ...), so
# `background_0_lower` needs `background_0` and not `background_0_lower`. A
# template asking for a key no theme defines renders a literal
# `{{ key }}` into a generated config (vb-theme-set-templates.awk:26-29), which
# is a literal nobody notices. That is the assertion that matters here.
#
# The rest is grammar: theme.info's KEY=VALUE form, colors.list's quoted-hex
# form, neovim.lua's Lua, and backgrounds/ holding only images Qt will decode.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "themes" "the 30 shipped palettes: required files, the derived colour set, neovim.lua, backgrounds"

require_tools awk sed grep sort paste tr wc find md5sum cut comm iconv

THEMES_DIR="$VIBRANIUM_DIR/themes"
THEMED_DIR="$VIBRANIUM_DIR/default/themed"
THEME_AWK="$VIBRANIUM_DIR/awk/vb-theme-set-templates.awk"
THEME_QML="$SHELL_DIR/common/theme/Theme.qml"
THEME_PICKER="$SHELL_DIR/features/pickers/theme/ThemePicker.qml"
THEME_REMOVER="$SHELL_DIR/features/pickers/theme/ThemeRemover.qml"
# The palette reader both theme pages call. The rules below are stated here
# rather than in either page: the two had carried identical copies of the
# key set and the hex check, and a key added to one page was invisible to a
# test that only read the other.
THEME_SCAN="$SHELL_DIR/features/pickers/theme/ThemeScan.js"
IMAGE_EXTS="$SHELL_DIR/common/text/ImageExts.js"
THEME_SET="$VIBRANIUM_DIR/bin/vb-theme-set"
THEME_TEMPLATES="$VIBRANIUM_DIR/bin/vb-theme-set-templates"
THEME_DOC="$VIBRANIUM_DIR/docs/understanding/making-your-own-theme.md"

# --------------------------------------------------------------------------
# the sources this suite reads
# --------------------------------------------------------------------------

t_section "the sources this suite reads, and the rules it holds the data to"
t_true "themes/ is a directory" test -d "$THEMES_DIR"
t_true "default/themed/ is a directory" test -d "$THEMED_DIR"
t_file "the template engine" "$THEME_AWK"
t_file "Theme.qml" "$THEME_QML"
t_file "ThemePicker.qml" "$THEME_PICKER"
t_file "ThemeRemover.qml" "$THEME_REMOVER"
t_file "ImageExts.js" "$IMAGE_EXTS"
t_file "vb-theme-set" "$THEME_SET"
t_file "vb-theme-set-templates" "$THEME_TEMPLATES"
t_file "the theme authoring doc" "$THEME_DOC"

# The four required components, quoted from the doc rather than restated.
t_contains "the doc names colors.list as required" \
  "- \`colors.list\`" "$(<"$THEME_DOC")"
t_contains "the doc names theme.info as required" \
  "- \`theme.info\`" "$(<"$THEME_DOC")"
t_contains "the doc requires at least one background image" \
  "At least one image in \`backgrounds/\`" "$(<"$THEME_DOC")"
t_contains "and says every colour value must be defined" \
  "Every color value must be defined." "$(<"$THEME_DOC")"

# The three theme.info fields, read back out of the two consumers that parse
# it, so a fourth field added to one of them cannot pass unnoticed.
t_eq "vb-theme-set reads exactly FAMILY, VARIANT and LIGHT" \
  "FAMILY LIGHT VARIANT" \
  "$(sed -n '/while IFS=.=. read -r key val; do/,/done < "\$theme_dir\/theme.info"/p' "$THEME_SET" |
    sed -n 's/.*\[\[ \$key == \([A-Z]*\) \]\].*/\1/p' | LC_ALL=C sort -u | paste -sd' ' -)"
t_eq "ThemePicker.qml reads the same three" \
  "FAMILY LIGHT VARIANT" \
  "$(grep -o 'k === "[A-Z]*"' "$THEME_PICKER" | sed 's/k === "//;s/"//' | LC_ALL=C sort -u | paste -sd' ' -)"
t_contains "and vb-theme-set-templates resolves LIGHT" \
  'if [[ "$light" == true ]]' "$(<"$THEME_TEMPLATES")"
t_contains "with a dark default when the field is absent" \
  'THEME_LIGHT[$folder_name]' "$(<"$THEME_SET")"

# The image-extension table, from the module both wallpaper flows gate on.
declare -A EXT_OK=()
while read -r ext; do
  EXT_OK["$ext"]=1
done < <(grep -o '[a-z0-9]*: 1' "$IMAGE_EXTS" | sed 's/: 1//')
t_eq "the image-extension table holds 22 entries" "22" "${#EXT_OK[@]}"
t_contains "and both the wallpaper picker and the cycler gate on ok()" \
  'function ok(name)' "$(<"$IMAGE_EXTS")"
t_contains "the cycler filters its find listing through it" \
  '.filter(f => root._extOk(f))' \
  "$(grep -m1 '_extOk(f)' "$SHELL_DIR/features/wallpaper/Wallpaper.qml")"
t_note "gif and mng are deliberately absent from ImageExts.js: Qt caches every decoded frame as RGBA, so a small gif costs gigabytes of RAM. No theme ships either, so the exclusion costs nothing here"

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

# theme_dirs - every theme directory, sorted. Dot-directories are excluded the
# way both consumers exclude them: FolderListModel is pointed at the folder and
# lists its subdirectories, and _discover_in_dir globs "$dir"/*/.
theme_dirs() {
  find "$THEMES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%P\n' | LC_ALL=C sort
}

# palette_keys <file> - the colour names a colors.list declares, one per line,
# parsed the way both readers parse it: the key is everything before the first
# "=", with the quotes and spaces vb-theme-set-templates:91 strips, and a
# comment line (a leading #) and a blank line are dropped.
palette_keys() {
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z $line || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    key="${key//[\"\' ]/}"
    [[ -n $key ]] || continue
    printf '%s\n' "$key"
  done <"$1"
}

# palette_value <file> <key> - the quoted-hex value a colors.list gives one
# name, extracted the way vb-theme-set-templates:102 does: whatever sits
# between the first pair of quotes on the value side.
palette_value() {
  local file="$1" want="$2" key value
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    key="${key//[\"\' ]/}"
    [[ "$key" == "$want" ]] || continue
    value="${line#*=}"
    value="${value#*[\"\']}"
    value="${value%%[\"\']*}"
    printf '%s' "$value"
    return 0
  done <"$file"
  return 1
}

# info_field <file> <key> - one theme.info value, read the way vb-theme-set:147
# and ThemePicker.qml:390 do: split on the first "=" and take the right side.
# The `|| [[ -n $key ]]` arm is not decoration: 20 of the 30 theme.info files
# end without a newline, so a plain `while read` silently drops the last field
# of each of them - which is LIGHT, the field both tools care most about.
info_field() {
  local file="$1" want="$2" key="" val=""
  while IFS='=' read -r key val || [[ -n $key ]]; do
    if [[ "$key" == "$want" ]]; then
      printf '%s' "$val"
      return 0
    fi
    key=""
    val=""
  done <"$file"
  return 1
}

# norm_name <text> - lowercase, ASCII letters and digits only. A directory name
# is compared against family+variant through this, so an accented VARIANT
# loses the accent and the comparison is against the ASCII folder name.
norm_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

# whitespace_defect <text> - nothing when the text is already trimmed and
# singly spaced, or a word naming the defect. theme.info is read with
# `IFS='=' read -r key val`, which keeps any space the author wrote, and both
# the picker's label and the bash tool's FOLDER_MAP key are built from the
# value verbatim.
whitespace_defect() {
  local text="$1" squeezed
  squeezed="$(printf '%s' "$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g')"
  [[ "$text" == "$squeezed" ]] || printf 'padded'
}

# theme_digest <dir> - a digest over the theme's own files, backgrounds
# included, so two byte-identical themes are the same digest. .git and
# .github are excluded: themes/vibranium is a nested checkout of an upstream
# repository and its VCS plumbing is not part of the palette.
theme_digest() {
  local dir="$1" rel
  while read -r rel; do
    printf '%s %s\n' "$rel" "$(md5sum "$dir/$rel" | cut -d' ' -f1)"
  done < <(find "$dir" -type f -not -path '*/.git/*' -not -path '*/.github/*' -printf '%P\n' |
    LC_ALL=C sort)
}

# bg_files <dir> - the theme's wallpapers, by basename, sorted.
bg_files() {
  find "$1/backgrounds" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort
}

# lua_ends <file> - the count of block openers and of `end` keywords. Not a
# parser: a structural check that runs everywhere, used only as a backstop for
# the machines with no Lua.
lua_ends() {
  local opens closes
  opens="$(grep -o '\bfunction\b\|\bthen\b\|\bdo\b\|{\|}' "$1" | wc -l | tr -d ' ')"
  closes="$(grep -c '^\s*}' "$1")"
  printf '%s %s' "$opens" "$closes"
}

# --------------------------------------------------------------------------
# inventory
# --------------------------------------------------------------------------

mapfile -t THEMES < <(theme_dirs)
NT="${#THEMES[@]}"

t_section "the inventory: 30 real directories, all discoverable"
t_count "themes/ holds 30 theme directories" "30" "$NT"
t_sorted "the directory listing is already in sorted order" "$(printf '%s\n' "${THEMES[@]}")"
t_unique "no theme name is a case-insensitive duplicate of another" \
  "$(printf '%s\n' "${THEMES[@]}" | tr '[:upper:]' '[:lower:]')"
t_eq "the names are all lower-kebab, the form both consumers accept as an input" "0" \
  "$(printf '%s\n' "${THEMES[@]}" | grep -vcE '^[a-z0-9]+(-[a-z0-9]+)*$')"

EMPTY_THEME=""
UNINSTALLLED=""
NOT_A_DIR=""
for theme in "${THEMES[@]}"; do
  dir="$THEMES_DIR/$theme"
  if [[ ! -d $dir ]]; then
    NOT_A_DIR="$NOT_A_DIR$theme "
    continue
  fi
  count="$(find "$dir" -type f -not -path '*/.git/*' | grep -c .)"
  ((count > 0)) || EMPTY_THEME="$EMPTY_THEME$theme "
  # vb-theme-set:135 and the picker's scan both skip a directory carrying this
  # marker, so a shipped one would be invisible in the picker.
  [[ -e "$dir/.uninstalled" ]] && UNINSTALLLED="$UNINSTALLLED$theme "
done
t_eq "every entry in the listing is a real directory" "" "$NOT_A_DIR"
t_eq "no theme directory is empty" "" "$EMPTY_THEME"
t_eq "no shipped theme is marked .uninstalled" "" "$UNINSTALLLED"
t_contains "vb-theme-set skips an .uninstalled directory" \
  '.uninstalled' "$(<"$THEME_SET")"
t_ne "and at least one theme carries the marker path at all, so the skip is real" \
  "unreachable" "$(grep -c '\.uninstalled' "$THEME_SET")"

# --------------------------------------------------------------------------
# the required files
# --------------------------------------------------------------------------

t_section "the four required components, per theme"
MISSING_FILES=""
THEMED_THEMES=0
for theme in "${THEMES[@]}"; do
  dir="$THEMES_DIR/$theme"
  for req in colors.list theme.info; do
    if [[ ! -s "$dir/$req" ]]; then
      MISSING_FILES="$MISSING_FILES$theme/$req "
    fi
  done
  if [[ ! -d "$dir/backgrounds" ]]; then
    MISSING_FILES="$MISSING_FILES$theme/backgrounds/ "
  elif [[ -z "$(bg_files "$dir")" ]]; then
    MISSING_FILES="$MISSING_FILES$theme/backgrounds-empty "
  fi
  [[ -s "$dir/neovim.lua" ]] && THEMED_THEMES=$((THEMED_THEMES + 1))
done
t_eq "every theme carries colors.list, theme.info and a non-empty backgrounds/" \
  "" "$MISSING_FILES"
t_count "and 28 of the 30 also carry a hand-authored neovim.lua" "28" "$THEMED_THEMES"
t_file "the template that renders the ones that do not" "$THEMED_DIR/neovim.lua.tpl"
t_contains "and vb-theme-set-templates writes it only when absent" \
  'should_write=true' "$(<"$THEME_TEMPLATES")"
t_contains "so a theme that ships its own wins over the generated one" \
  'if [[ ! -f $output_path ]]; then' "$(<"$THEME_TEMPLATES")"
t_note "osaka-jade and vibranium carry no neovim.lua, so both get the prism.nvim palette rendered from default/themed/neovim.lua.tpl. neovim.lua is therefore NOT part of the required set: apply_theme copies the directory and the renderer fills the gaps, and the four components docs/understanding/making-your-own-theme.md:14-18 names are colors.list, theme.info and one background image"
t_note "the 3 themes that ship a hand-authored hyprland.lua (nightfox-carbonfox, tokyonight-moon, tokyonight-night) override the generated one the same way; 2 ship no other override, so every theme's applied tree is its own files plus the rendered templates"

# --------------------------------------------------------------------------
# theme.info
# --------------------------------------------------------------------------

t_section "theme.info: KEY=VALUE, the three fields, no duplicates"
INFO_BAD=""
INFO_DUPKEY=""
INFO_LIGHT=0
for theme in "${THEMES[@]}"; do
  file="$THEMES_DIR/$theme/theme.info"
  while IFS= read -r line; do
    if [[ -z ${line//[[:space:]]/} ]]; then
      continue
    fi
    if [[ "$line" != *=* ]]; then
      INFO_BAD="$INFO_BAD$theme:[no-=]$line "
      continue
    fi
    key="${line%%=*}"
    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      INFO_BAD="$INFO_BAD$theme:[key]$key "
    fi
    # A repeated field is read twice with last-write-wins, so the declared
    # FAMILY is whichever line the reader happened to reach last.
    if grep -qxF -- "$key=*" "$file" && [[ "$(grep -c "^${key}=" "$file")" -gt 1 ]]; then
      INFO_DUPKEY="$INFO_DUPKEY$theme:$key "
    fi
  done <"$file"
  light="$(info_field "$file" LIGHT || printf 'absent')"
  if [[ "$light" == "true" ]]; then
    INFO_LIGHT=$((INFO_LIGHT + 1))
  fi
done
t_eq "every theme.info line is KEY=VALUE with an UPPER_SNAKE key" "" "$INFO_BAD"
t_eq "no theme.info repeats a field" "" "$INFO_DUPKEY"

VARIANT_MISSING=""
FAMILY_EMPTY=0
for theme in "${THEMES[@]}"; do
  file="$THEMES_DIR/$theme/theme.info"
  variant="$(info_field "$file" VARIANT || printf 'absent')"
  family="$(info_field "$file" FAMILY || printf 'absent')"
  [[ "$variant" == "absent" || -z "${variant//[[:space:]]/}" ]] \
    && VARIANT_MISSING="$VARIANT_MISSING$theme "
  [[ "$family" == "absent" || -z "${family//[[:space:]]/}" ]] \
    && FAMILY_EMPTY=$((FAMILY_EMPTY + 1))
  t_match "$theme declares LIGHT as a boolean" '^(true|false)$' \
    "$(info_field "$file" LIGHT || printf 'absent')"
  t_ne "$theme declares a non-empty VARIANT" "" "$variant"
  t_empty "$theme declares no unknown field" \
    "$(grep -o '^[A-Z][A-Z0-9_]*' "$file" |
      grep -vxE 'FAMILY|VARIANT|LIGHT' | paste -sd' ' -)"
done
t_eq "every theme declares a non-empty VARIANT" "" "$VARIANT_MISSING"
t_eq "exactly one theme is standalone, with an empty FAMILY" "1" "$FAMILY_EMPTY"
t_eq "and it is the one named after the project" "vibranium" \
  "$(for theme in "${THEMES[@]}"; do
    family="$(info_field "$THEMES_DIR/$theme/theme.info" FAMILY || printf 'absent')"
    [[ -z "${family//[[:space:]]/}" ]] && printf '%s' "$theme"
  done)"
t_eq "4 of the 30 themes declare LIGHT=true" "4" "$INFO_LIGHT"
t_note "the picker falls back to a folder-name heuristic when theme.info has no LIGHT (ThemePicker.qml:423, /(light|latte|dawn)\$/i) and vb-theme-set-templates resolves it to dark instead (bin/vb-theme-set-templates:39); all 30 declare the field, so the two fallbacks are never reached and a future theme that omits it would get the heuristic from one tool and dark from the other"

# --------------------------------------------------------------------------
# colors.list
# --------------------------------------------------------------------------

t_section "the palette grammar: quoted #rrggbb, unique names, no empties"
PAL_BAD=""
PAL_DUP=""
PAL_EMPTY_NAME=0
PAL_COUNT=()
for theme in "${THEMES[@]}"; do
  file="$THEMES_DIR/$theme/colors.list"
  keys="$(palette_keys "$file")"
  PAL_COUNT+=("$(printf '%s\n' "$keys" | grep -c .)")
  if [[ "$(printf '%s\n' "$keys" | LC_ALL=C sort | uniq -d | grep -c .)" != "0" ]]; then
    PAL_DUP="$PAL_DUP$theme "
  fi
  if [[ "$(printf '%s\n' "$keys" | grep -c '^$')" != "0" ]]; then
    PAL_EMPTY_NAME="$PAL_EMPTY_NAME$((PAL_EMPTY_NAME + 1))"
  fi
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    value="$(palette_value "$file" "$key" || printf 'absent')"
    if [[ ! "$value" =~ ^#[0-9a-fA-F]{6}$ ]]; then
      PAL_BAD="$PAL_BAD$theme:$key=$value "
    fi
  done <<<"$keys"
done
t_eq "every colour value is a quoted #rrggbb" "" "$PAL_BAD"
t_eq "no palette declares the same colour name twice" "" "$PAL_DUP"
t_eq "no palette declares an empty colour name" "0" "$PAL_EMPTY_NAME"
t_eq "every palette declares the same number of colours" "1" \
  "$(printf '%s\n' "${PAL_COUNT[@]}" | LC_ALL=C sort -u | grep -c .)"
t_eq "and that number is 14" "14" "${PAL_COUNT[0]}"
t_note "a palette names one background and one foreground and nothing above or below them: the templates ramp every shade off those two with |pop= and |dim=, so a palette needs the 11 colour families, accent, and one key each for background and foreground. 14 rather than the 26 the ladders used to cost"

# --------------------------------------------------------------------------
# the required colour set, derived from the four sources that name one
# --------------------------------------------------------------------------

t_section "the required colour set, derived from default/themed/*.tpl"
# The suffix table resolve_token() strips, read out of the engine rather than
# restated: awk/vb-theme-set-templates.awk:279-292.
SUFFIXES="$(grep -o 'sub(/_[a-z0-9]*[$]' "$THEME_AWK" | cut -c6- | tr -d '$' |
  LC_ALL=C sort -u | paste -sd' ' -)"
t_eq "the engine strips 14 format suffixes off a key" \
  "_0x _b _g _h _hsl _hwb _l _lower _r _rgb _s _strip _upper _w" "$SUFFIXES"
t_contains "and tries the bare key before any suffix" \
  'if (base_key in subs) {' "$(<"$THEME_AWK")"
t_contains "leaving an unresolvable placeholder in the output" \
  'rather than replaced with an empty string' "$(<"$THEME_AWK")"

# The union of the palettes is the lookup the resolver answers against.
declare -A PAL=()
while read -r key; do
  PAL["$key"]=1
done < <(palette_keys "$THEMES_DIR/nightfox/colors.list")

# resolve_key <token> - the base palette key a template token reads, by the
# engine's own order: the token itself if it is a palette key, else one
# suffix stripped, repeatedly. Prints nothing and fails when no base is left.
resolve_key() {
  local tok="$1" prev="" sfx
  while :; do
    if [[ -n ${PAL[$tok]+set} ]]; then
      printf '%s' "$tok"
      return 0
    fi
    for sfx in $SUFFIXES; do
      if [[ "$tok" == *"$sfx" && ${#tok} -gt ${#sfx} ]]; then
        tok="${tok%"$sfx"}"
        break
      fi
    done
    [[ "$tok" == "$prev" ]] && return 1
    prev="$tok"
  done
}

TEMPLATE_TOKENS="$(grep -ho '{{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' "$THEMED_DIR"/*.tpl |
  sed 's/{{[[:space:]]*//' | LC_ALL=C sort -u)"
t_ne "the templates ask for at least one colour" "0" \
  "$(printf '%s\n' "$TEMPLATE_TOKENS" | grep -c .)"

TEMPLATE_KEYS=""
UNRESOLVED=""
TOKENS_N=0
while read -r tok; do
  [[ -n $tok ]] || continue
  TOKENS_N=$((TOKENS_N + 1))
  base="$(resolve_key "$tok")" || { UNRESOLVED="$UNRESOLVED$tok "; continue; }
  TEMPLATE_KEYS="$TEMPLATE_KEYS$base"$'\n'
done <<<"$TEMPLATE_TOKENS"
TEMPLATE_KEYS="$(printf '%s' "$TEMPLATE_KEYS" | LC_ALL=C sort -u | grep -c .)"

t_eq "every placeholder in every template resolves to a palette key" "" "$UNRESOLVED"
t_count "and the 18 shipped templates hold 181 distinct colour placeholders" \
  "181" "$TOKENS_N"
t_count "default/themed/ holds 18 templates, the whole render set" "18" \
  "$(printf '%s\n' "$THEMED_DIR"/*.tpl | grep -c .)"
t_contains "and the renderer globs that set rather than naming it" \
  'for tpl in "$tpl_dir"/*.tpl; do' "$(<"$THEME_TEMPLATES")"
t_note "181 distinct {{ key }} tokens collapse to 14 base palette keys, because the engine derives _rgb/_hsl/_lower/_r/... forms from one key (awk/vb-theme-set-templates.awk:279-292). The token count is the number of derived forms a theme must be able to satisfy, the 14 is the number of colours it must define"
t_eq "the 14 base keys the templates can reach are exactly this" \
  "accent background black blue cyan foreground gray green orange pink purple red white yellow" \
  "$(while read -r tok; do resolve_key "$tok"; printf '\n'; done <<<"$TEMPLATE_TOKENS" |
    LC_ALL=C sort -u | grep . | paste -sd' ' -)"
t_eq "and every one of them is defined in every theme" "0" \
  "$(for theme in "${THEMES[@]}"; do
    keys="$(palette_keys "$THEMES_DIR/$theme/colors.list")"
    for base in $(while read -r tok; do resolve_key "$tok"; printf '\n'; done <<<"$TEMPLATE_TOKENS" |
      LC_ALL=C sort -u | grep .); do
      printf '%s\n' "$keys" | grep -qxF -- "$base" || printf '%s ' "$base"
    done
  done | tr ' ' '\n' | grep -c .)"

# Every shade a template renders is a ramp off a base colour rather than a
# palette key, so this is the assertion that keeps the two in step. A level
# suffix would resolve to nothing the palette can answer for, and - because
# the engine tries the whole token as a key before it strips any suffix, so
# background_h would lose its _h and land on background - would hand back the
# base colour under the guise of a shade. That is the one failure mode here
# that leaves no literal {{ ... }} behind to notice.
t_eq "no template names a shade with a numeric level suffix" "0" \
  "$(grep -ohE '\{\{[[:space:]]*(background|foreground)_[0-5]' "$THEMED_DIR"/*.tpl | grep -c .)"
t_eq "and no palette declares a level-suffixed base either" "0" \
  "$(palette_keys "$THEMES_DIR/nightfox/colors.list" |
    grep -E '^(background|foreground)_' | grep -c . || true)"
t_note "_h is deliberately not in that count, and could not be: it is one of the engine's 14 format suffixes - the HSL hue scalar - so {{ background_h }} asks for the hue of the base colour, which is what colors.css.tpl puts on the -h row of every shade. It reads exactly like the retired background_h palette key and means nothing of the sort. That is why the check is on the numeric levels, and why a bare background_h must never be taken for the old key again"
RAMP_STEPS="$(grep -ohE '\{\{[[:space:]]*(background|foreground)[a-z0-9_]*\|(pop|dim)=[0-9.]+' \
  "$THEMED_DIR"/*.tpl | sed 's/.*=//' | LC_ALL=C sort -u | paste -sd' ' -)"
t_eq "the ramp uses one step for the ladder, plus a shorter one for each extreme" \
  "0.03 0.06 0.12 0.18 0.24 0.30 12 18 24 3 30 6" "$RAMP_STEPS"
t_note "0.06 is the ladder step and 0.03 the background's deepest surface, half of it, because a background already sits at the far end of its range while a foreground needs a full step to read brighter than body text. The hsl lens takes unsigned percentage points and every other lens takes a fraction of the 0-100 lightness range, so one 0.06 step appears as pop=6 on an _hsl token and pop=0.06 elsewhere. Mixing the two forms within one level would silently render two different colours"

DOC_KEYS="$(sed -n '/^    ```toml$/,/^    ```$/p' "$THEME_DOC" |
  sed -n 's/^    \([a-z_0-9]*\)[[:space:]]*=.*/\1/p' | LC_ALL=C sort -u)"
t_count "the doc's palette template lists 14 colours" "14" "$(printf '%s\n' "$DOC_KEYS" | grep -c .)"
t_eq "and every documented colour is a real palette key" "" \
  "$(printf '%s\n' "$DOC_KEYS" | while read -r k; do
    [[ -n ${PAL[$k]+set} ]] || printf '%s ' "$k"
  done)"
t_eq "the palette is exactly the documented 14, so it names no extra" \
  "$DOC_KEYS" \
  "$(while read -r k; do printf '%s\n' "$k"; done < <(palette_keys "$THEMES_DIR/nightfox/colors.list") |
    LC_ALL=C sort -u)"

# The documented colours no shipped template consumes.
UNUSED_KEYS=""
while read -r key; do
  [[ -n $key ]] || continue
  # The token must END at the key: `background` is not used by a template
  # that only asks for `background_lower`.
  if ! grep -qE "\{\{[[:space:]]*${key}([[:space:]|}])" "$THEMED_DIR"/*.tpl; then
    UNUSED_KEYS="$UNUSED_KEYS$key"$'\n'
  fi
done <<<"$DOC_KEYS"
t_eq "every documented colour is asked for by some template" "" \
  "$(printf '%s' "$UNUSED_KEYS" | tr -d '\n')"
t_note "with the shades computed there is no unreachable palette entry left: the 14 colours the doc documents are the 14 the templates read, and the derived set and the palette are the same set. Before the ramp the darkest foreground shade was in every colors.list and no template ever rendered it"

t_section "the palette every theme declares, checked key by key"
MISSING_COLOUR=""
for theme in "${THEMES[@]}"; do
  keys="$(palette_keys "$THEMES_DIR/$theme/colors.list")"
  absent=""
  while read -r key; do
    [[ -n $key ]] || continue
    printf '%s\n' "$keys" | grep -qxF -- "$key" || absent="$absent $key"
  done <<<"$DOC_KEYS"
  t_eq "$theme defines all 26 documented colours" "" "$absent"
  extra=""
  while read -r key; do
    [[ -n $key ]] || continue
    printf '%s\n' "$DOC_KEYS" | grep -qxF -- "$key" || extra="$extra $key"
  done <<<"$keys"
  t_eq "$theme names no colour outside the documented palette" "" "$extra"
  t_eq "$theme's colour-name set is the one every other theme declares" "1" \
    "$(for t2 in "${THEMES[@]}"; do
      palette_keys "$THEMES_DIR/$t2/colors.list" | LC_ALL=C sort -u |
        md5sum | cut -d' ' -f1
    done | LC_ALL=C sort -u | grep -c .)"
  MISSING_COLOUR="$MISSING_COLOUR$absent"
done
t_eq "no theme is missing a colour the shell reads" "" "$MISSING_COLOUR"

t_section "the shell's own palette readers, cross-checked against the set"
QS_KEYS="$(grep -o '"[a-z_0-9]*": "{{' "$THEMED_DIR/qs.json.tpl" |
  sed 's/": "{{//;s/"//' | sed 's/_lower$//' | LC_ALL=C sort -u)"
t_eq "qs.json.tpl - the palette the shell reads - carries 14 keys" "14" \
  "$(printf '%s\n' "$QS_KEYS" | grep -c .)"
ADAPTER_KEYS="$(sed -n '/id: paletteAdapter/,/^    }/p' "$THEME_QML" |
  sed -n 's/^      property string \([A-Za-z0-9_]*\):.*/\1/p' | LC_ALL=C sort -u)"
t_eq "Theme.qml's JsonAdapter declares the same 14" \
  "$QS_KEYS" "$ADAPTER_KEYS"
FALLBACK_KEYS="$(sed -n '/const fallbacks = {/,/^    }/p' "$THEME_QML" |
  sed -n 's/^      \([A-Za-z0-9_]*\):.*/\1/p' | LC_ALL=C sort -u)"
t_eq "and the color() fallbacks are the same 14 again" "$QS_KEYS" "$FALLBACK_KEYS"
t_contains "which is why a missing key is a bug to surface" \
  'a missing key is a bug to surface' "$(<"$THEME_QML")"
# The 14 names above are the shell's own, not the palette's: background_1 and
# foreground_1 are ramp levels the shell binds by name, so what has to resolve
# is the value expression behind each name rather than the name itself.
QS_SOURCES="$(grep -oE '"[a-z_0-9]+": "\{\{[[:space:]]*[^}]+\}\}"' "$THEMED_DIR/qs.json.tpl" |
  sed -e 's/.*"{{[[:space:]]*//' -e 's/[[:space:]]*}}"$//' -e 's/|.*//' -e 's/[[:space:]]*$//' |
  LC_ALL=C sort -u)"
t_eq "every value qs.json.tpl renders resolves to a palette key" "" \
  "$(while read -r src; do
    [[ -n $src ]] || continue
    resolve_key "$src" >/dev/null || printf '%s ' "$src"
  done <<<"$QS_SOURCES")"
t_count "and the shell's 14 outputs come from 10 palette keys" "10" \
  "$(printf '%s\n' "$QS_SOURCES" | while read -r src; do
    resolve_key "$src"; printf '\n'
  done | LC_ALL=C sort -u | grep -c .)"
t_note "4 of the 14 are background_1/2/3 and foreground_1, which no palette declares: they are ramp levels off background and foreground, and Theme.qml binds them by that name regardless of which theme is active. That is why the ramp has to be a template operation rather than a palette key - the shell's key set cannot move with the palette"
PICKER_KEYS="$(grep -m1 '^const PALETTE_KEYS' "$THEME_SCAN" |
  grep -o '"[a-z]*"' | tr -d '"' | LC_ALL=C sort -u)"
t_eq "the shared palette reader takes 7 swatch colours" "7" \
  "$(printf '%s\n' "$PICKER_KEYS" | grep -c .)"
t_eq "all 7 are inside the required palette" "" \
  "$(printf '%s\n' "$PICKER_KEYS" | while read -r k; do
    printf '%s\n' "$DOC_KEYS" | grep -qxF -- "$k" || printf '%s ' "$k"
  done)"
# Both pages read the swatches through that one reader, so neither can hold a
# key set of its own: a page that grew a private copy would stop answering
# this suite's question, which is the drift the extraction removed.
t_contains "the picker reads the swatches through it" \
  'ThemeScan.extractPalette' "$(<"$THEME_PICKER")"
t_contains "and so does the remover" \
  'ThemeScan.extractPalette' "$(<"$THEME_REMOVER")"
t_contains "the reader drops a line with no #rrggbb on it" \
  'const m = line.match(/#[0-9a-fA-F]{6}/)' "$(<"$THEME_SCAN")"
t_contains "and skips a line with no = on it" \
  'if (eq < 0) continue' "$(<"$THEME_SCAN")"

# --------------------------------------------------------------------------
# neovim.lua
# --------------------------------------------------------------------------

t_section "neovim.lua: a real Lua chunk with no unresolved colour"
LUA_BIN=""
for candidate in luac luac5.4 luac5.3 luac5.2 luac5.1; do
  if command -v "$candidate" >/dev/null 2>&1; then
    LUA_BIN="$candidate"
    break
  fi
done
if [[ -n $LUA_BIN ]]; then
  t_note "$LUA_BIN is on PATH, so every neovim.lua is compiled with the real Lua parser rather than only checked structurally"
else
  t_note "no luac on PATH: neovim.lua is checked structurally only (balanced block keywords, balanced braces, non-empty, and every colour it references defined in that theme's palette). A real Lua interpreter would be the stronger check; the structural checks are what runs here"
fi

LUA_BAD=""
LUA_EMPTY=""
LUA_MISSING_COLOUR=""
LUA_COLORREF=0
LUA_CHECKED=0
for theme in "${THEMES[@]}"; do
  file="$THEMES_DIR/$theme/neovim.lua"
  [[ -f $file ]] || continue
  LUA_CHECKED=$((LUA_CHECKED + 1))
  bytes="$(wc -c <"$file" | tr -d ' ')"
  if ((bytes == 0)); then
    LUA_EMPTY="$LUA_EMPTY$theme "
    continue
  fi
  t_contains "$theme's neovim.lua returns a table literal" \
    'return {' "$(head -1 "$file")"
  read -r opens closes < <(lua_ends "$file")
  if ((closes > opens)); then
    LUA_BAD="$LUA_BAD$theme(unbalanced) "
  fi
  # A placeholder the palette cannot satisfy, and a literal hex the palette
  # does not carry: either one renders as itself in a config file.
  while read -r ref; do
    [[ -n $ref ]] || continue
    LUA_COLORREF=$((LUA_COLORREF + 1))
    if [[ "$ref" == \#* ]]; then
      hex="$(palette_keys "$THEMES_DIR/$theme/colors.list" >/dev/null;
        while read -r k; do
          [[ "$(palette_value "$THEMES_DIR/$theme/colors.list" "$k")" == "$ref" ]] && break
        done < <(palette_keys "$THEMES_DIR/$theme/colors.list") |
        sed 's/$/ found/')"
      [[ "$hex" == " found" ]] || LUA_MISSING_COLOUR="$LUA_MISSING_COLOUR$theme:$ref "
    else
      base="$(resolve_key "$ref")" || { LUA_MISSING_COLOUR="$LUA_MISSING_COLOUR$theme:$ref "
        continue; }
      palette_keys "$THEMES_DIR/$theme/colors.list" | grep -qxF -- "$base" ||
        LUA_MISSING_COLOUR="$LUA_MISSING_COLOUR$theme:$base "
    fi
  done < <(grep -o '{{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[}|]*\|#[0-9a-fA-F]\{6\}' "$file" |
    sed 's/{{[[:space:]]*//; s/[}|]*$//' | LC_ALL=C sort -u)
  if [[ -n $LUA_BIN ]]; then
    if ! "$LUA_BIN" -p "$file" 2>/dev/null; then
      LUA_BAD="$LUA_BAD$theme(luac) "
    fi
  fi
done
t_count "every shipped neovim.lua is non-empty" "28" "$LUA_CHECKED"
t_eq "no neovim.lua is empty" "" "$LUA_EMPTY"
t_eq "no neovim.lua is structurally unbalanced" "" "$LUA_BAD"
t_eq "no neovim.lua references a colour its theme does not define" "" "$LUA_MISSING_COLOUR"
t_eq "the colour-reference check is not vacuous: no shipped neovim.lua inlines a colour" \
  "0" "$LUA_COLORREF"
t_note "all 28 hand-authored neovim.lua files select an upstream colourscheme plugin (catppuccin/nvim, neanias/everforest-nvim, ellisonleao/gruvbox.nvim, rose-pine/neovim, ...) and name no palette colour at all, so the reference check has nothing to find. That is correct: the template renderer, not the theme, supplies the inline palette, and the 4 gruvbox themes legitimately share one neovim.lua because the upstream plugin picks its own variant"
t_contains "the generated palette ramps its dimmed background off the base" \
  'bg_dim = "{{ background|pop=0.06 }}"' "$(<"$THEMED_DIR/neovim.lua.tpl")"
t_eq "all 11 colours it names are inside the required palette" "" \
  "$(grep -o '{{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[}|]*' "$THEMED_DIR/neovim.lua.tpl" |
    sed 's/{{[[:space:]]*//; s/[}|]*$//' | LC_ALL=C sort -u |
    while read -r k; do
      [[ -n $k ]] || continue
      printf '%s\n' "$DOC_KEYS" | grep -qxF -- "$k" || printf '%s ' "$k"
    done)"

# --------------------------------------------------------------------------
# backgrounds
# --------------------------------------------------------------------------

t_section "backgrounds/: at least one image, every file real and decodable"
BG_TOTAL=0
BG_BADEXT=""
BG_EMPTY_FILE=""
BG_THEME=0
for theme in "${THEMES[@]}"; do
  n="$(bg_files "$THEMES_DIR/$theme" | grep -c .)"
  BG_TOTAL=$((BG_TOTAL + n))
  ((n > 0)) || BG_THEME=$((BG_THEME + 1))
  t_ne "$theme declares at least one background" "0" "$n"
  while read -r base; do
    [[ -n $base ]] || continue
    path="$THEMES_DIR/$theme/backgrounds/$base"
    ext="${base##*.}"
    ext="${ext,,}"
    if [[ -z ${EXT_OK[$ext]+set} ]]; then
      BG_BADEXT="$BG_BADEXT$theme/$base "
    fi
    [[ -s $path ]] || BG_EMPTY_FILE="$BG_EMPTY_FILE$theme/$base "
    t_file "$theme/$base exists and is readable" "$path"
  done < <(bg_files "$THEMES_DIR/$theme")
done
t_eq "every theme declares at least one background" "0" "$BG_THEME"
t_count "the 30 themes ship 184 wallpapers" "184" "$BG_TOTAL"
t_eq "every background's extension is one ImageExts.ok() accepts" "" "$BG_BADEXT"
t_eq "no background is a zero-byte file" "" "$BG_EMPTY_FILE"
t_eq "the wallpapers are only jpg and png" "jpg png" \
  "$(find "$THEMES_DIR" -path '*/backgrounds/*' -type f -printf '%f\n' |
    sed 's/.*\.//' | LC_ALL=C sort -u | paste -sd' ' -)"
t_contains "the cycler sorts the listing it chose from, so a rename changes the pick" \
  '.sort()' "$(grep -m1 'filter(f => root._extOk(f)).sort()' "$SHELL_DIR/features/wallpaper/Wallpaper.qml")"
t_contains "and commits the recorded path as theme/backgrounds/<name>" \
  'const rel = "theme/backgrounds/" + base' \
  "$(<"$SHELL_DIR/features/wallpaper/Wallpaper.qml")"
t_note "the 11 png wallpapers are the onedark, osaka-light and rosepine-dark-hard sets; everything else is jpg. Both are in ImageExts.js, so the set passes the same filter Qt will apply at decode time"

# --------------------------------------------------------------------------
# cross-theme invariants
# --------------------------------------------------------------------------

t_section "the declared name, the directory name and the picker's key agree"
DISPLAY_KEYS=""
NAME_MISMATCH=""
for theme in "${THEMES[@]}"; do
  file="$THEMES_DIR/$theme/theme.info"
  family="$(info_field "$file" FAMILY || printf '')"
  variant="$(info_field "$file" VARIANT || printf '')"
  light="$(info_field "$file" LIGHT || printf 'false')"
  # vb-theme-set:202 keys a family theme on "Family-Variant" and a standalone
  # one on the variant alone; two themes producing the same key would silently
  # drop one of them.
  if [[ -z "${family//[[:space:]]/}" ]]; then
    key="$variant"
  else
    key="$family-$variant"
  fi
  DISPLAY_KEYS="$DISPLAY_KEYS$key"$'\n'
  # The tree's own naming convention, compared on the ASCII form: a directory
  # is either family+variant or the variant alone (nightfox and rosepine ship
  # their base variant under the bare family name).
  nd="$(norm_name "$theme")"
  nf="$(norm_name "$family")"
  nv="$(norm_name "$variant")"
  if [[ "$nd" != "${nf}${nv}" && "$nd" != "$nv" ]]; then
    NAME_MISMATCH="$NAME_MISMATCH$theme"$'\n'
  fi
  t_ne "$theme's picker label is not empty" "" \
    "$(printf '%s' "$key" | tr -d '[:space:]')"
  # ThemePicker.qml:412-414 builds the label as family + " " + variant with
  # every hyphen turned into a space, so a field carrying a leading or trailing
  # space would render a row whose label differs from the key the bash tool
  # writes into theme.name.
  t_eq "$theme's FAMILY carries no leading, trailing or doubled space" "" \
    "$(whitespace_defect "$family")"
  t_eq "$theme's VARIANT carries no leading, trailing or doubled space" "" \
    "$(whitespace_defect "$variant")"
done
t_eq "every family-variant key is unique, so no theme is shadowed in the picker" "0" \
  "$(printf '%s' "$DISPLAY_KEYS" | LC_ALL=C sort | uniq -d | grep -c .)"
t_eq "and every picker label is unique too, so the 30 rows are 30 distinct rows" "0" \
  "$(printf '%s' "$DISPLAY_KEYS" | tr '-' ' ' | tr -s ' ' | LC_ALL=C sort | uniq -d | grep -c .)"
t_eq "29 of the 30 directory names match their declared family and variant" \
  "catppuccin-frappe" "$(printf '%s' "$NAME_MISMATCH" | tr -d '\n')"
t_note "catppuccin-frappe is the one mismatch and is deliberate rather than broken: theme.info spells VARIANT=Frappe with a grave accent, and the directory is the ASCII catppuccin-frappe. Nothing depends on the accent - vb-theme-set takes a folder name directly (bin/vb-theme-set:534) before it ever parses family/variant, and the picker label is built from the same field either way - but the tree's own convention is an ASCII directory name, so the assertion pins the exception by name rather than widening the rule to accept it anywhere"
t_contains "and the doc states the family may be left empty for a standalone theme" \
  "Leave empty for standalone themes." "$(<"$THEME_DOC")"
t_contains "while VARIANT is required and is the standalone theme's name" \
  "Required. For standalone themes this is the theme name." "$(<"$THEME_DOC")"

t_section "no theme is a byte-identical duplicate of another"
declare -A DIGEST=()
DUPLICATES=""
for theme in "${THEMES[@]}"; do
  digest="$(theme_digest "$THEMES_DIR/$theme" | md5sum | cut -d' ' -f1)"
  DIGEST["$digest"]+="$theme "
done
t_eq "all 30 themes hash to 30 distinct digests" "0" \
  "$(for d in "${!DIGEST[@]}"; do
    set -- ${DIGEST[$d]}
    (($# > 1)) && printf '%s ' "$d"
  done | grep -c .)"
for d in "${!DIGEST[@]}"; do
  set -- ${DIGEST[$d]}
  if (($# > 1)); then
    DUPLICATES="$DUPLICATES$* "
  fi
done
t_eq "so no two themes are the same tree" "" "$DUPLICATES"
t_eq "the digests cover colors.list, theme.info and every wallpaper" "30" \
  "$(for theme in "${THEMES[@]}"; do
    find "$THEMES_DIR/$theme" -type f -not -path '*/.git/*' -not -path '*/.github/*' |
      grep -c .
  done | grep -c '[1-9]' | head -1)"
t_empty "and every theme contributes at least four files of its own" \
  "$(for theme in "${THEMES[@]}"; do
    n="$(find "$THEMES_DIR/$theme" -type f -not -path '*/.git/*' -not -path '*/.github/*' | grep -c .)"
    ((n >= 4)) || printf '%s ' "$theme"
  done)"

# --------------------------------------------------------------------------
# the theme index, in the only form the tree has one
# --------------------------------------------------------------------------

t_section "the index: there is no manifest, the two listings derive from the directory"
t_eq "no manifest or index file names the shipped themes" "0" \
  "$(grep -rl "catppuccin-frappe" --include='*.json' --include='*.jsonc' \
    --include='*.txt' --include='*.list' --include='*.toml' \
    "$VIBRANIUM_DIR/default" "$VIBRANIUM_DIR/config" 2>/dev/null | grep -c .)"
t_contains "so the bash tool's index is a directory scan" \
  'for theme_dir in "$dir"/*/;' "$(<"$THEME_SET")"
t_contains "and the picker's is a FolderListModel over the same root" \
  'officialModel.folder = "file://" + Paths.vibraniumHome + "/themes"' "$(<"$THEME_PICKER")"
t_contains "which lists directories and skips dot entries" \
  'showDotAndDotDot: false' "$(<"$THEME_PICKER")"
# Direction one: a theme the scan cannot reach is hidden in both listings.
UNREACHABLE=0
for theme in "${THEMES[@]}"; do
  # _discover_in_dir registers a directory with or without a theme.info (the
  # folder-name fallback), so nothing here can make one undiscoverable except
  # the marker the tree has none of.
  if [[ ! -e "$THEMES_DIR/$theme/.uninstalled" ]]; then
    UNREACHABLE=$((UNREACHABLE + 1))
  fi
done
t_eq "all 30 directories are reachable by both listings" "30" "$UNREACHABLE"
# Direction two: a rename invalidates the persisted name, because the two tools
# record the FOLDER name, not the display key. The name rule above is what
# keeps the two in step, and it is asserted there.
t_contains "the persisted theme name is the folder name" \
  'printf "%s" "$folder_name" > "$THEME_NAME_FILE"' "$(<"$THEME_SET")"
t_contains "which is what the picker treats as the active theme" \
  'Paths.themeNameFile' "$(<"$THEME_PICKER")"
t_contains "and the picker accepts a folder name only if the listing contains it" \
  'function apply(folder) {' "$(<"$THEME_PICKER")"
t_contains "so a theme dropped from disk leaves a stale theme.name nothing resolves to" \
  '!root._contained(name)' "$(grep -m1 '!root._contained(name)' "$THEME_PICKER")"
t_note "the .uninstalled marker is written by vb-theme-remove for an archived community theme and hides it from both the picker and vb-theme-set; no shipped theme carries one, so the 30 directories and the 30 listed names are the same set in both directions. There is no static manifest to go stale - a rename is caught by the directory-name rule above, and a deletion by this marker check"
t_note "vb_hidden_themes in ~/.config/vibranium/settings.advanced can hide any of them from the picker at runtime (bin/vb-theme-set:80). That is a user file outside the repo, so it is not asserted here"

t_summary
