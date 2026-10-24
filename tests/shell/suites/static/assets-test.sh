#!/bin/bash
# Suite: assets - the shipped SVGs are reachable, referenced and consistent.
#
# shell/common/theme/Icons.qml is the only icon backend in the shell: a boot
# scan reads every svg under shell/assets/icons, keys it on the BASENAME, and
# Icons.url(name) hands callers a recolored data: URL. Nothing errors on a
# miss - url() returns "" and the Image draws nothing - so a name that does
# not resolve is invisible at runtime and loud here instead.
#
# Three contracts are asserted, and they are different contracts:
#
#   1. Direction.  Every name the tree hands to Icons must be a shipped file.
#   2. Coverage.  Every shipped file must be named by something, or listed in
#      a README table. Dead weight and half-finished renames look identical
#      from the filesystem, which is why this half of the check exists.
#   3. Loadability. Non-empty, an <svg> root, a closing </svg>, and symlinks
#      that resolve - the scan runs under `set -e`, so one broken symlink
#      takes the whole icon cache down and every icon in the shell goes blank
#      at once rather than one at a time.
#
# The weather set is asserted separately because it is the one place where
# three files have to agree with each other: services/weather/Model.js
# decides the name, shell/assets/icons/weather/ has to have the file, and
# icons/README.md has to have the provenance row. Two of those three are
# currently short one name and that is reported precisely, because the
# existing js suite already pins the same drift on the Model.js side.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "assets" "shipped icons: resolvable, referenced, loadable, documented"

ASSETS_DIR="$SHELL_DIR/assets"
ICONS_DIR="$ASSETS_DIR/icons"
ICONS_README="$ICONS_DIR/README.md"
ASSETS_README="$ASSETS_DIR/README.md"
ICONS_QML="$SHELL_DIR/common/theme/Icons.qml"
WEATHER_MODEL="$SHELL_DIR/services/weather/Model.js"

# Recorded inventories. These move when a glyph is added, which is a real
# change and should show up in a diff rather than be absorbed.
RECORDED_SVG_COUNT=181
RECORDED_SUBDIRS="battery file hypr player weather"
RECORDED_SYMLINKS=4
RECORDED_BATTERY="battery-0
battery-1
battery-2
battery-3
battery-charging"
# Shipped svgs that the coverage scan above reports as unreferenced. The scan
# reads .qml/.js under shell/ and the provenance table, so an entry here means
# "nothing in shell/ names it" - not "nothing in the repo names it". Icons
# reached through default/vibranium/ data files are invisible to it.
#
# The set is empty. Every shipped svg has a provenance row in
# assets/icons/README.md, and a provenance row is a reference: the coverage
# scan reads the table, so a documented glyph is a named glyph. Ten of the
# hypr/ themed-settings set are named by nothing in shell/ at all - the
# Hyprland settings catalog names them in 30-input.jsonc, 31-gaps.jsonc and
# 38-general.jsonc, which flows SettingsLib -> Settings.qml -> Menu.qml ->
# Entry.qml -> Icon.qml - and the provenance table is what makes them
# visible to the scan. The table is the reference those ten were missing.
RECORDED_ORPHANS=""
# Paths shell/assets/README.md cites that resolve to nothing. The set is
# empty: the document names the paths that are on disk. It used to cite
# tests/run-all.sh and two tests/shell.d/*.sh files, a stale-reference defect
# in a README rather than an assets defect, and the citations now name the
# real harness paths.
RECORDED_UNRESOLVED_CITATIONS=""
# Every name services/weather/Model.js can return from iconForWmoCode or
# iconForCode. Sixteen, and the set is the contract - it is what an SVG has
# to exist for, so it is pinned exactly and a new mapping is a deliberate edit.
RECORDED_WEATHER_NAMES="weather-clear-day
weather-clear-night
weather-drizzle
weather-fog-day
weather-fog-night
weather-overcast
weather-partly-cloudy-day
weather-partly-cloudy-night
weather-rain
weather-showers-day
weather-showers-night
weather-sleet
weather-snow
weather-snow-showers-day
weather-snow-showers-night
weather-thunderstorm"

# ---------------------------------------------------------------------------
# The resolution rule, read out of Icons.qml rather than assumed.
# ---------------------------------------------------------------------------
t_section "the resolution rule, taken from Icons.qml"
t_file "the icon resolver exists" "$ICONS_QML"
t_true "the icon directory exists" test -d "$ICONS_DIR"
ICONS_SRC="$(cat "$ICONS_QML")"
t_contains "it scans recursively for svg" "find " "$ICONS_SRC"
t_contains "with a name filter" "-name '*.svg'" "$ICONS_SRC"
t_contains "and keys each entry on the basename" 'b=${f##*/}' "$ICONS_SRC"
t_contains "and strips the .svg extension from that key" '${b%.svg}' "$ICONS_SRC"
t_contains "url() returns empty for an unknown name" 'if (raw === undefined) return ""' "$ICONS_SRC"

# The same scan, reimplemented here from the rule above. If the rule in
# Icons.qml ever changes, this set stops matching what the resolver produces
# and the asset-existence assertions below start answering the wrong
# question - so the derivation is asserted against the real files.
mapfile -t SVG_FILES < <(find "$ICONS_DIR" -type f,l -name '*.svg' | LC_ALL=C sort)
KEYS="$(printf '%s\n' "${SVG_FILES[@]}" | sed -E 's#.*/##; s#\.svg$##' | LC_ALL=C sort -u)"
t_not_empty "the scan finds svg files" "$KEYS"
t_count "no two svgs share a basename" "${#SVG_FILES[@]}" "$(printf '%s\n' "$KEYS" | grep -c .)"
# The subdirectory is organization on disk, not part of the name, so no key
# may contain a slash. A key that did would be a name the resolver can never
# produce from Icons.url().
t_empty "no key carries a directory prefix" "$(printf '%s\n' "$KEYS" | grep '/' || true)"
t_true "a nested asset resolves by basename alone" \
  grep -qx "weather-clear-day" <<<"$KEYS"
t_false "and not by its path" \
  grep -qx "weather/weather-clear-day" <<<"$KEYS"

# ---------------------------------------------------------------------------
# 1. Direction: every name the tree hands to Icons has a file behind it.
# ---------------------------------------------------------------------------
t_section "every referenced name resolves to a shipped file"

# (a) Every literal first argument to Icons.url(). Precise by construction:
# this is the resolver's own entry point.
#
# The identifier boundary matters: the pattern is anchored so it cannot match
# the tail of a LONGER name. AppIcons.url() is a different function - it tries
# the shipped set first and the platform icon theme second, so it legitimately
# takes names that are not shipped assets (that is the whole point of the
# fallback). Scanning it as if it were Icons.url() asserted that a platform
# theme name had to live in assets/icons, which is not a contract anything
# holds.
URL_NAMES="$(grep -rhoE '(^|[^A-Za-z0-9_.])Icons\.url\([[:space:]]*"[A-Za-z0-9._-]+"' \
  "$SHELL_DIR" --include=*.qml --include=*.js \
  | sed -E 's/.*"([^"]+)"/\1/' | LC_ALL=C sort -u)"
t_not_empty "the tree calls Icons.url() with literal names" "$URL_NAMES"

# (b) Every `name:` handed to an Icon / IconButton / IconImage block. `name`
# is an overloaded property across the tree (IPC verbs, tool ids, settings
# rows all use it too), so it cannot be matched globally - it is matched
# inside an icon block, by brace depth, which is the only reading of it that
# means an asset.
ICON_NAME_AWK=$(cat <<'AWK'
# Report every `name: "..."` literal assigned inside an Icon / IconButton /
# IconImage block, as "file<TAB>name".
#
# Brace depth is tracked from the block's own opening brace, so a `name:`
# belonging to a nested child (a ToolTip, a Rectangle) is not mistaken for
# the Icon's. `//` line comments are stripped first: no icon name contains
# "//", and a commented-out Icon would otherwise be counted as live.
{
  s = $0
  sub(/\/\/.*/, "", s)
  n_open = gsub(/\{/, "{", s)
  n_close = gsub(/\}/, "}", s)
  for (i = 0; i < n_open; i++) {
    depth++
    is_icon[depth] = (s ~ /(^|[^A-Za-z0-9_])(Icon|IconButton|IconImage)[[:space:]]*\{/) ? 1 : 0
  }
  if (depth > 0 && is_icon[depth] == 1) {
    rest = s
    while (match(rest, /(^|[^A-Za-z0-9_])name:[[:space:]]*"[A-Za-z0-9][A-Za-z0-9._-]*"/)) {
      lit = substr(rest, RSTART, RLENGTH)
      sub(/^[^"]*"/, "", lit)
      sub(/"$/, "", lit)
      printf "%s\t%s\n", FILENAME, lit
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
  for (i = 0; i < n_close; i++) if (depth > 0) depth--
}
AWK
)
mapfile -t ALL_QML < <(shell_qml_files)
ICON_NAME_SITES="$(printf '%s\n' "${ALL_QML[@]}" | xargs awk "$ICON_NAME_AWK" | LC_ALL=C sort -u)"
ICON_NAMES="$(cut -f2 <<<"$ICON_NAME_SITES" | LC_ALL=C sort -u)"
t_not_empty "the tree names icons on Icon blocks" "$ICON_NAMES"

# A name the resolver cannot produce is the failure this section exists for,
# so the diagnostic names the file that asked for it rather than the name
# alone.
MISSING_URL="$(LC_ALL=C comm -23 <(printf '%s\n' "$URL_NAMES") <(printf '%s\n' "$KEYS") | tr '\n' ' ')"
t_empty "every Icons.url() literal is a shipped asset" "$MISSING_URL"
MISSING_ICON="$(LC_ALL=C comm -23 <(printf '%s\n' "$ICON_NAMES") <(printf '%s\n' "$KEYS") \
  | while read -r miss; do
      [[ -n $miss ]] || continue
      printf '%s <- %s; ' "$miss" "$(cut -f1 <<<"$ICON_NAME_SITES" | grep -c . >/dev/null; awk -F'\t' -v n="$miss" '$2 == n { print $1 }' <<<"$ICON_NAME_SITES" | head -2 | tr '\n' ' ')"
    done)"
t_empty "every name on an Icon block is a shipped asset" "$MISSING_ICON"

# ---------------------------------------------------------------------------
# 2. Coverage: no orphan assets.
# ---------------------------------------------------------------------------
t_section "no orphan assets"
# A file counts as referenced if a .qml/.js file names it, or if a README
# table lists it. The .js half matters: services/weather/Model.js is the
# only thing that names weather-rain, and a name that exists to be returned
# at runtime is a live reference even though no QML file spells it.
LITERALS="$(grep -rhoE '"[A-Za-z0-9][A-Za-z0-9._-]*"' \
  "$SHELL_DIR" --include=*.qml --include=*.js | tr -d '"' | LC_ALL=C sort -u)"
# The provenance table's first column: "| a, b, c | source | license |".
README_NAMES="$(awk -F'|' '/^\| /{ gsub(/^ +| +$/, "", $2); n = split($2, a, ",");
  for (i = 1; i <= n; i++) { gsub(/^ +| +$/, "", a[i]); if (a[i] ~ /^[a-z][a-z0-9-]*$/) print a[i] } }' \
  "$ICONS_README" | LC_ALL=C sort -u)"
t_not_empty "the icons README has a provenance table" "$README_NAMES"

ORPHANS="$(LC_ALL=C comm -23 <(printf '%s\n' "$KEYS") \
  <(printf '%s\n' "$LITERALS" "$README_NAMES" | LC_ALL=C sort -u) | tr '\n' ' ' | sed 's/ $//')"
ORPHAN_COUNT="$(printf '%s\n' "$KEYS" | LC_ALL=C comm -23 - \
  <(printf '%s\n' "$LITERALS" "$README_NAMES" | LC_ALL=C sort -u) | grep -c . || true)"
# Reported by path, as the coverage contract asks, and pinned so that a
# *new* orphan fails this suite rather than joining a list nobody reads.
# The set is empty: every shipped svg has a provenance row in
# assets/icons/README.md, and the table is a reference the scan reads. A
# glyph that is documented is a glyph that is named, whether or not any
# .qml file names it.
t_note "$ORPHAN_COUNT shipped svgs are referenced by nothing: no .qml/.js literal and no README table row. Paths: $ORPHANS"
t_eq "no shipped svg is an orphan" "$RECORDED_ORPHANS" "$ORPHANS"

# Names that only the README carries are not orphans - the table is a stated
# reference - but they are the ones a rename leaves behind, so they are
# counted where a reader can see them.
DOC_ONLY="$(LC_ALL=C comm -23 <(printf '%s\n' "$KEYS") <(printf '%s\n' "$LITERALS") | tr '\n' ' ' | sed 's/ $//')"
DOC_ONLY_COUNT="$(printf '%s\n' "$KEYS" | LC_ALL=C comm -23 - <(printf '%s\n' "$LITERALS") | grep -c . || true)"
t_note "$DOC_ONLY_COUNT of those are named only by the provenance table, never by code: $DOC_ONLY"

# The reverse drift: a provenance row for an icon that is not on disk. The
# README's own rule is that every icon has a row, so a row without a file is
# a rename that happened on one side only. Reported with the row's line
# number, not asserted, because deciding which side is right is a docs
# change and not this suite's call.
ROW_ONLY="$(LC_ALL=C comm -13 <(printf '%s\n' "$KEYS") <(printf '%s\n' "$README_NAMES") \
  | while read -r gone; do
      [[ -n $gone ]] || continue
      rows="$(awk -F'|' -v want="$gone" '/^\| /{ n = split($2, a, ",");
        for (i = 1; i <= n; i++) { g = a[i]; gsub(/^ +| +$/, "", g); if (g == want) { print FNR; break } } }' \
        "$ICONS_README" | paste -sd, -)"
      printf '%s (icons/README.md:%s) ' "$gone" "$rows"
    done | sed 's/ $//')"
ROW_ONLY_COUNT="$(printf '%s\n' "$KEYS" | LC_ALL=C comm -13 - <(printf '%s\n' "$README_NAMES") | grep -c . || true)"
t_note "$ROW_ONLY_COUNT provenance rows name an icon that is not on disk: $ROW_ONLY"

# ---------------------------------------------------------------------------
# 3. Loadability: the scan must survive every file it reads.
# ---------------------------------------------------------------------------
t_section "every svg is loadable"
ZERO_BYTE="$(find "$ICONS_DIR" -type f -name '*.svg' -size 0 -printf '%P ' || true)"
t_empty "no svg is zero bytes" "$ZERO_BYTE"
t_count "the shipped set is the recorded size" "$RECORDED_SVG_COUNT" "${#SVG_FILES[@]}"

# Well-formed enough to decode: an <svg> root on the first line and a
# closing </svg> on the last non-blank one. The icon scan strips newlines
# and hands the text to recolor(), which rewrites it as a data: URL - a
# truncated document fails at decode time, in the Image, with nothing in the
# shell's own output.
NO_ROOT=""
NO_CLOSE=""
BAD_TAIL=""
for f in "${SVG_FILES[@]}"; do
  first="$(head -1 "$f")"
  case $first in
    '<svg'*) ;;
    *) NO_ROOT+="${f#"$ICONS_DIR"/} " ;;
  esac
  if ! grep -q '</svg>' "$f"; then
    NO_CLOSE+="${f#"$ICONS_DIR"/} "
  fi
  last="$(grep -v '^[[:space:]]*$' "$f" | tail -1)"
  if [[ $last != *'</svg>'* ]]; then
    BAD_TAIL+="${f#"$ICONS_DIR"/} "
  fi
done
t_empty "every svg opens with an <svg> root element" "$NO_ROOT"
t_empty "every svg closes its root element" "$NO_CLOSE"
t_empty "the closing tag is the last thing in the file" "$BAD_TAIL"

# Symlinks: the scan is `find -type f,l -name '*.svg'` under `set -e -o
# pipefail`, and a broken symlink makes the `$(<"$f")` read fail, which
# fails the scan, which leaves Icons.ready false and _raw empty for the whole
# session. So a dangling link is a whole-shell outage, not a missing glyph.
mapfile -t SYMLINKS < <(find "$ICONS_DIR" -type l | LC_ALL=C sort)
t_count "the symlink count is the recorded one" "$RECORDED_SYMLINKS" "${#SYMLINKS[@]}"
BROKEN_LINKS="$(find "$ICONS_DIR" -xtype l -printf '%P ' || true)"
t_empty "every symlinked icon resolves to a real file" "$BROKEN_LINKS"
t_not_empty "the symlinks resolve" "${SYMLINKS[*]}"

# ---------------------------------------------------------------------------
# The layout the two READMEs describe.
# ---------------------------------------------------------------------------
t_section "the directory layout matches the READMEs"
SUBDIRS="$(find "$ICONS_DIR" -mindepth 1 -type d -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')"
t_eq "the icon directory has exactly the documented subdirectories" \
  "$RECORDED_SUBDIRS" "$(printf '%s\n' "$SUBDIRS" | tr -s ' ' | sed 's/^ //; s/ $//' | tr '\n' ' ' | sed 's/ $//')"
t_count "the subdirectory count" "5" "$(find "$ICONS_DIR" -mindepth 1 -type d | wc -l)"
t_not_empty "battery/ holds the battery set" "$(find "$ICONS_DIR/battery" -name '*.svg' -printf '%f ' || true)"
t_not_empty "file/ holds the file-type set" "$(find "$ICONS_DIR/file" -name '*.svg' -printf '%f ' || true)"
t_not_empty "hypr/ holds the hyprland set" "$(find "$ICONS_DIR/hypr" -name '*.svg' -printf '%f ' || true)"
t_not_empty "player/ holds the transport set" "$(find "$ICONS_DIR/player" -name '*.svg' -printf '%f ' || true)"
t_not_empty "weather/ holds the weather set" "$(find "$ICONS_DIR/weather" -name '*.svg' -printf '%f ' || true)"

# ---------------------------------------------------------------------------
# The weather set: a real cross-file contract between three files.
# ---------------------------------------------------------------------------
t_section "the weather set is a contract between Model.js, disk and the README"
t_file "the weather model exists" "$WEATHER_MODEL"

# The names the two mapping functions can return, extracted from the
# function bodies only - from `function iconForWmoCode` up to the
# REQUIRED ICON SET comment - so the comment listing below is read as a
# separate thing and cannot be mistaken for the code.
WEATHER_RETURNABLE="$(awk '/^function iconForWmoCode/,/^\/\/ REQUIRED ICON SET/' "$WEATHER_MODEL" \
  | grep -oE 'weather-[a-z-]+' | LC_ALL=C sort -u)"
t_eq "the functions return exactly the recorded names" "$RECORDED_WEATHER_NAMES" "$WEATHER_RETURNABLE"
t_count "which is sixteen names" "16" "$(printf '%s\n' "$WEATHER_RETURNABLE" | grep -c .)"

WEATHER_ON_DISK="$(find "$ICONS_DIR/weather" -name 'weather-*.svg' -printf '%f\n' \
  | sed 's/\.svg$//' | LC_ALL=C sort -u)"
WEATHER_MISSING="$(LC_ALL=C comm -23 <(printf '%s\n' "$WEATHER_RETURNABLE") <(printf '%s\n' "$KEYS") | tr '\n' ' ' | sed 's/ $//')"
# The other direction: a weather-*.svg the mappers never return. Exactly one
# is legitimate (weather-droplet, the humidity row) and any other is a glyph
# nothing can reach, which is the "renamed on one side only" case.
WEATHER_EXTRA="$(LC_ALL=C comm -13 <(printf '%s\n' "$WEATHER_RETURNABLE") <(printf '%s\n' "$WEATHER_ON_DISK") \
  | tr '\n' ' ' | sed 's/ $//')"
t_empty "every name the mappers return has an svg on disk" "$WEATHER_MISSING"
t_eq "and the only weather-*.svg no mapper returns is the humidity glyph" \
  "weather-droplet" "$WEATHER_EXTRA"
# weather-droplet is the humidity row in Weather.qml, not a condition glyph,
# so it is a member of the directory and not of the mapper's set. Pinned so
# the two sets are never quietly merged.
t_contains "weather-droplet is the humidity row, not a condition" \
  'icon: "weather-droplet"' "$(cat "$SHELL_DIR/services/weather/Weather.qml")"

# The two documents, checked rather than assumed - the existing js suite
# (services-calendar-weather) already pins the Model.js half of this drift
# at its own line 2384, so what is added here is the README half and the
# file:line. The README half is the provenance table's weather row, whose
# line is computed so the note does not rot when the table is edited.
README_WEATHER="$(grep -oE 'weather-[a-z-]+' "$ICONS_README" | LC_ALL=C sort -u)"
README_WEATHER_MISSING="$(LC_ALL=C comm -23 <(printf '%s\n' "$WEATHER_RETURNABLE") <(printf '%s\n' "$README_WEATHER") | tr '\n' ' ')"
README_WEATHER_ROW="$(grep -n 'weather-clear-day' "$ICONS_README" | head -1 | cut -d: -f1)"
t_note "icons/README.md's weather row (line ${README_WEATHER_ROW}) documents $(printf '%s\n' "$README_WEATHER" | grep -c .) of the 16 names the mappers return; it omits: $README_WEATHER_MISSING"
SOURCE_COMMENT="$(awk '/^\/\/ REQUIRED ICON SET/,/^\/\/ \(15 files/' "$WEATHER_MODEL")"
SOURCE_COMMENT_LINE="$(grep -n 'REQUIRED ICON SET' "$WEATHER_MODEL" | head -1 | cut -d: -f1)"
t_note "services/weather/Model.js:${SOURCE_COMMENT_LINE} still says \"(15 files\" for a set of 16 - the comment omits $(LC_ALL=C comm -23 <(printf '%s\n' "$WEATHER_RETURNABLE") <(printf '%s\n' "$SOURCE_COMMENT" | grep -oE 'weather-[a-z-]+' | LC_ALL=C sort -u) | tr '\n' ' ')"
# The omitted name is a real asset, so nothing renders empty: the stale part
# is the count in the comment, not the glyph.
t_true "the omitted name is a real asset, so nothing renders empty" \
  test -f "$ICONS_DIR/weather/weather-rain.svg"

# ---------------------------------------------------------------------------
# The battery set: contiguous, with the charging glyph.
# ---------------------------------------------------------------------------
t_section "the battery set is complete and contiguous"
BATTERY_KEYS="$(grep '^battery' <<<"$KEYS" | LC_ALL=C sort)"
t_eq "the battery set is exactly 0..3 plus charging" "$RECORDED_BATTERY" "$BATTERY_KEYS"
t_count "which is five glyphs" "5" "$(printf '%s\n' "$BATTERY_KEYS" | grep -c .)"
BATTERY_MISSING=""
for n in 0 1 2 3; do
  grep -qx "battery-$n" <<<"$KEYS" || BATTERY_MISSING+="battery-$n "
done
t_empty "battery-0 through battery-3 are all present" "$BATTERY_MISSING"
t_true "and battery-charging is present" grep -qx "battery-charging" <<<"$KEYS"
# Contiguity is the property, not the count: a hole reads as a battery
# percentage with no glyph and no error.
BATTERY_LEVELS="$(printf '%s\n' "$BATTERY_KEYS" | sed -n 's/^battery-\([0-9]\)$/\1/p' | tr '\n' ' ')"
t_eq "the levels are 0 1 2 3 with no gap" "0 1 2 3 " "$BATTERY_LEVELS"

# ---------------------------------------------------------------------------
# The assets README: it exists, and what it points at is there.
# ---------------------------------------------------------------------------
t_section "the assets README and the paths it lists"
t_file "shell/assets/README.md exists" "$ASSETS_README"
t_file "and documents the icon directory" "$ICONS_README"

# Every backticked path in shell/assets/README.md that contains a slash. The
# README writes the five icon subdirectories bare (`battery/`, not
# `icons/battery/`) because it is describing the contents of icons/ from
# inside shell/assets/, so a path is resolved against three roots in the
# order the document itself reads: assets/, icons/, and the repo root.
README_PATHS="$(grep -ohE '`[A-Za-z0-9_./-]+/`|`[A-Za-z0-9_./-]+/[A-Za-z0-9_.-]+`' "$ASSETS_README" \
  | tr -d '`' | grep '/' | LC_ALL=C sort -u)"
t_not_empty "the assets README lists paths" "$README_PATHS"
mapfile -t README_PATH_LIST <<<"$README_PATHS"
ASSET_LIST=()
SOURCE_LIST=()
TEST_PATHS=()
for p in "${README_PATH_LIST[@]}"; do
  [[ -n $p ]] || continue
  if [[ -e "$ASSETS_DIR/$p" || -e "$ICONS_DIR/$p" ]]; then
    ASSET_LIST+=("$p")
  elif [[ -e "$VIBRANIUM_DIR/$p" ]]; then
    SOURCE_LIST+=("$p")
  else
    TEST_PATHS+=("$p")
  fi
done
SOURCE_LIST_JOINED="${SOURCE_LIST[*]}"
TEST_PATHS_JOINED="${TEST_PATHS[*]}"
# Every path the README lists lands in exactly one of three buckets, and the
# three are pinned. The unresolvable bucket is empty: the document cites
# tests/shell/run-all.sh and tests/shell/suites/static/assets-test.sh, which
# are the real harness paths, and the paths it names inside the tree are the
# ones that are there. A citation that resolves to nothing is a
# stale-reference defect in a README, and it fails here rather than being
# reported.
t_contains "it lists the icons subdirectories" "battery/" "$README_PATHS"
t_contains "and the rest of them too" "weather/" "$README_PATHS"
t_count "it lists all five icon subdirectories" "5" \
  "$(for d in battery file hypr player weather; do
      grep -qx "$d/" <<<"$README_PATHS" && printf 'x'
    done | wc -c | tr -d ' ')"
t_contains "it names Icons.qml, the resolver" "shell/common/theme/Icons.qml" "$SOURCE_LIST_JOINED"
t_count "and the example asset it walks through" "1" \
  "$(grep -c '^icons/weather/weather-clear-day\.svg$' <<<"$README_PATHS")"
t_count "eight of the paths it lists are assets" "8" "${#ASSET_LIST[@]}"
t_count "five are repo-relative sources" "5" "${#SOURCE_LIST[@]}"
t_eq "and none of them is unresolvable" "$RECORDED_UNRESOLVED_CITATIONS" "$TEST_PATHS_JOINED"

t_summary
