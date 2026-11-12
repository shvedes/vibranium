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
#   2. Coverage.  Every shipped file must be named by something in the tree.
#      Dead weight and half-finished renames look identical from the
#      filesystem, which is why this half of the check exists.
#   3. Loadability. Non-empty, an <svg> root, a closing </svg>, and symlinks
#      that resolve - the scan runs under `set -e`, so one broken symlink
#      takes the whole icon cache down and every icon in the shell goes blank
#      at once rather than one at a time.
#
# The weather set is asserted separately because it is the one place where
# the mapping code and the shipped files have to agree: the names
# services/weather/Model.js returns and shell/assets/icons/weather/ has to
# have.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "assets" "shipped icons: resolvable, referenced, loadable, documented"

ASSETS_DIR="$SHELL_DIR/assets"
ICONS_DIR="$ASSETS_DIR/icons"
ICONS_QML="$SHELL_DIR/common/theme/Icons.qml"
WEATHER_MODEL="$SHELL_DIR/services/weather/Model.js"

# Recorded inventories. These move when a glyph is added, which is a real
# change and should show up in a diff rather than be absorbed.
RECORDED_SVG_COUNT=187
RECORDED_SUBDIRS="battery file hypr player weather"
RECORDED_SYMLINKS=4
RECORDED_BATTERY="battery-0
battery-1
battery-2
battery-3
battery-charging"
# Shipped svgs that the coverage scan above reports as unreferenced. The scan
# reads .qml, .js and config data under shell/, so an entry here means
# "nothing in the tree names it".
#
# Two glyphs are shipped but named nowhere: moon.svg and wifi-cog.svg. They
# are pinned rather than removed so that a rename elsewhere cannot hide a
# genuinely dead asset behind them.
RECORDED_ORPHANS="moon wifi-cog"
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
# A file counts as referenced if the tree names it: a .qml/.js literal, or a
# name carried in the settings catalog's JSON data. The .js half matters:
# services/weather/Model.js is the only thing that names weather-rain, and a
# name returned at runtime is a live reference even though no QML file spells
# it. The JSON half is the same kind of reference for the settings icons.
LITERALS="$(grep -rhoE '"[A-Za-z0-9][A-Za-z0-9._-]*"' \
  "$SHELL_DIR" --include=*.qml --include=*.js --include=*.json \
  --include=*.jsonc | tr -d '"' | LC_ALL=C sort -u)"

ORPHANS="$(LC_ALL=C comm -23 <(printf '%s\n' "$KEYS") \
  <(printf '%s\n' "$LITERALS" | LC_ALL=C sort -u) | tr '\n' ' ' | sed 's/ $//')"
ORPHAN_COUNT="$(printf '%s\n' "$KEYS" | LC_ALL=C comm -23 - \
  <(printf '%s\n' "$LITERALS" | LC_ALL=C sort -u) | grep -c . || true)"
# Reported by path, as the coverage contract asks, and pinned so that a
# *new* orphan fails this suite rather than joining a list nobody reads.
t_note "$ORPHAN_COUNT shipped svgs are referenced by no .qml/.js literal. Paths: $ORPHANS"
t_eq "no shipped svg is an orphan" "$RECORDED_ORPHANS" "$ORPHANS"

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
# The shipped directory layout.
# ---------------------------------------------------------------------------
t_section "the directory layout"
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

t_summary
