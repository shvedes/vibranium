#!/bin/bash
# Suite: layers - the import-direction contract in shell/README.md.
#
# The specification is shell/README.md, "Layers and import direction". Every
# assertion below restates one rule from it, and the rule is quoted in the
# section header that enforces it.
#
#   "boot ──────────────►  everything else
#    (boot is the only thing allowed to import all layers)"
#   "features ──────►  common, services, own layer"
#   "services  ──────►  common, own layer"
#   "common   ──────►  nothing but Qt/Quickshell + sibling common code"
#
#   common   must never "import any other layer, relative or versioned"
#   services must never "import features/"
#   features must never "import boot/, or features/bar <-> features/wallpaper"
#   boot     must never "be imported by anything else"
#
# The resolver finds every dependency edge in the tree, not only the ones that
# appear on an import line. Four kinds of edge are resolved, all in awk:
#
#   module  `import qs.x` / `import qs.x as A`  -> the module named by the
#                                                   qmldir whose module line
#                                                   is `module qs.x`
#   relqml  `import "path"` inside a .qml       -> a file relative to the source
#   reljs   `.import "path"` inside a .js       -> a sibling file
#   member  `A.member`, A a module alias        -> a member of that module
#
# Qt and Quickshell imports are marked external: they name no qmldir in the
# tree, they belong to no layer, and they cannot violate a direction rule. All
# three other kinds resolve, and a violation is reported as
# `path:line -> target [kind detail]`.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "layers" "the four-layer import-direction contract from shell/README.md"
require_tools awk find sort

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-layers.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------
# The resolver.
# --------------------------------------------------------------------------

# 1. The module table: every qmldir's `module` line, against its directory.
while IFS= read -r qmldir; do
  mod="$(awk '$1 == "module" { print $2; exit }' "$qmldir")"
  printf '%s\tshell/%s\n' "$mod" "$(rel_to_shell "$(dirname "$qmldir")")"
done < <(shell_qmldir_files) | LC_ALL=C sort -u >"$WORK/modules.tsv"

# 2. Every file in the tree, so a resolved path can be checked for existence.
find "$SHELL_DIR" -type f -printf '%P\n' | sed "s|^|shell/|" | LC_ALL=C sort >"$WORK/files.txt"

# 3. The raw edges. One awk program buffers a whole source file before
#    emitting anything, because a bare member reference can be read through an
#    alias that an earlier line declared.
cat >"$WORK/scan.awk" <<'AWK'
BEGIN { FS = "\t" }
FNR == 1 {
  if (seen) flush()
  seen = 1
  p = index(FILENAME, root)
  file = (p == 1) ? "shell/" substr(FILENAME, length(root) + 1) : FILENAME
  delete body
  delete alias
  n = 0
}
{
  n++
  body[n] = $0
  line = $0
  if (line ~ /^[ \t]*\.import[ \t]+"/) {
    s = line; sub(/^[ \t]*\.import[ \t]+"/, "", s); sub(/".*$/, "", s)
    print file "\t" n "\treljs\t" s
  }
  if (line ~ /^[ \t]*import[ \t]+"/) {
    s = line; sub(/^[ \t]*import[ \t]+"/, "", s); sub(/".*$/, "", s)
    print file "\t" n "\trelqml\t" s
  }
  if (line ~ /^[ \t]*import[ \t]+[A-Za-z_][A-Za-z0-9_.]*/) {
    s = line; sub(/^[ \t]*import[ \t]+/, "", s)
    mod = s; al = ""
    if (s ~ /[ \t]+as[ \t]+[A-Za-z_][A-Za-z0-9_]*$/) {
      al = s; sub(/^.*[ \t]+as[ \t]+/, "", al)
      sub(/[ \t]+as[ \t]+[A-Za-z_][A-Za-z0-9_]*$/, "", mod)
    }
    print file "\t" n "\tmodule\t" mod
    if (al != "" && !(al in alias)) alias[al] = mod
  }
}
function flush(   i, re, ln, a, rest, p, len, m) {
  for (a in alias) {
    print file "\t" a "\t" alias[a] > aliasfile
    re = "(^|[^A-Za-z0-9_.\"])" a "\\.[A-Za-z_][A-Za-z0-9_]*"
    for (i = 1; i <= n; i++) {
      ln = body[i]
      if (ln ~ "^[ \t]*(import|\\.import)") continue
      rest = ln
      while (match(rest, re)) {
        p = RSTART; len = RLENGTH
        m = substr(rest, p, len)
        rest = substr(rest, p + len)
        if (p > 1) m = substr(m, 2)
        print file "\t" i "\tmember\t" a "\t" substr(m, length(a) + 2)
      }
    }
  }
}
END { if (seen) flush(); close(aliasfile) }
AWK

# 4. The join. Every edge is given the layer it comes from and the layer it
#    reaches, so a direction rule is one comparison.
cat >"$WORK/join.awk" <<'AWK'
BEGIN {
  FS = "\t"
  while ((getline ln < modfile) > 0) { split(ln, a, "\t"); moddir[a[1]] = a[2] }
  while ((getline ln < alfile) > 0) { split(ln, a, "\t"); aliasmod[a[1] SUBSEP a[2]] = a[3] }
  while ((getline ln < exfile) > 0) exists[ln] = 1
}
function norm(p,   sp, parts, stack, top, i, out) {
  sp = split(p, parts, "/")
  delete stack; top = 0
  for (i = 1; i <= sp; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (top > 0) top--; continue }
    stack[++top] = parts[i]
  }
  out = ""
  for (i = 1; i <= top; i++) out = (out == "" ? stack[i] : out "/" stack[i])
  return out
}
function layer(p) {
  if (p ~ /^shell\/boot(\/|$)/) return "boot"
  if (p ~ /^shell\/common(\/|$)/) return "common"
  if (p ~ /^shell\/services(\/|$)/) return "services"
  if (p ~ /^shell\/features(\/|$)/) return "features"
  if (p ~ /^shell\/[^/]+$/) return "composition"
  return "stray"
}
function sublayer(p) {
  if (p ~ /^shell\/features\/bar(\/|$)/) return "bar"
  if (p ~ /^shell\/features\/wallpaper(\/|$)/) return "wallpaper"
  return "-"
}
{
  split($0, e, "\t")
  src = e[1]; ln = e[2]; kind = e[3]; d4 = e[4]; d5 = e[5]
  target = "-"; tkind = "?"
  if (kind == "module") {
    if (d4 in moddir) { target = moddir[d4]; tkind = "module" }
    else if (d4 ~ /^Qt[.A-Z]/ || d4 ~ /^Quickshell([.]|$)/) tkind = "external"
    else tkind = "unknown-module"
  } else if (kind == "reljs" || kind == "relqml") {
    base = src; sub(/\/[^\/]*$/, "", base)
    target = norm(base "/" d4)
    if (target in exists) tkind = "file"
    else if (target "/qmldir" in exists) tkind = "dir"
    else tkind = "missing"
  } else if (kind == "member") {
    am = aliasmod[src SUBSEP e[4]]
    if (am == "") tkind = "noalias"
    else if (am in moddir) { target = moddir[am]; tkind = "module" }
    else if (am ~ /^Qt[.A-Z]/ || am ~ /^Quickshell([.]|$)/) tkind = "external"
    else tkind = "unknown-module"
  }
  printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
    src, ln, kind, (kind == "member" ? d4 "." d5 : d4), target, tkind, \
    layer(target), sublayer(target), layer(src), sublayer(src)
}
AWK

mapfile -t SOURCES < <(
  { find "$SHELL_DIR" -name '*.qml' -type f; find "$SHELL_DIR" -name '*.js' -type f; } |
    LC_ALL=C sort
)
awk -v root="$SHELL_DIR/" -v aliasfile="$WORK/aliases.tsv" \
  -f "$WORK/scan.awk" "${SOURCES[@]}" >"$WORK/edges.tsv"
awk -F'\t' -v modfile="$WORK/modules.tsv" -v alfile="$WORK/aliases.tsv" \
  -v exfile="$WORK/files.txt" -f "$WORK/join.awk" "$WORK/edges.tsv" \
  >"$WORK/resolved.tsv"

# Fields of resolved.tsv:
#   1 source  2 line  3 kind  4 detail  5 target
#   6 how it resolved  7 target layer  8 target sub-layer
#   9 source layer  10 source sub-layer

# offenders <awk-expr> - one `path:line -> target [kind detail]` per edge the
# expression selects, so a failure names the line that broke the rule.
offenders() {
  awk -F'\t' "$1" "$WORK/resolved.tsv" |
    awk -F'\t' '{ printf "%s:%s -> %s [%s %s]\n", $1, $2, $5, $3, $4 }'
}

# rule <label> <awk-expr> - the expression must select no edge at all.
rule() {
  local label="$1" expr="$2" n
  n="$(offenders "$expr" | wc -l | tr -d ' ')"
  t_eq "$label" "0" "$n"
  if ((n > 0)); then
    t_note "offenders for \"$label\":"$'\n'"$(offenders "$expr")"
  fi
}

# layer_files <layer> - the .qml and .js files a layer owns, which is what the
# README's "Files" column counts.
layer_files() {
  case "$1" in
    composition) find "$SHELL_DIR" -maxdepth 1 -type f \( -name '*.qml' -o -name '*.js' \) ;;
    *) find "$SHELL_DIR/$1" -type f \( -name '*.qml' -o -name '*.js' \) ;;
  esac | wc -l | tr -d ' '
}

# strays - every .qml and .js in the tree that belongs to no layer at all.
strays() {
  printf '%s\n' "${SOURCES[@]}" | sed "s|^$SHELL_DIR/|shell/|" | awk '
    /^shell\/(boot|common|features|services)\// { next }
    $0 == "shell/shell.qml" { next }
    { print }'
}

EDGES="$(wc -l <"$WORK/resolved.tsv" | tr -d ' ')"

# --------------------------------------------------------------------------
t_section "the four layers exist, and the README's file counts still hold"
# The table: composition 1, boot 3, features 148, services 26, common 127.
# layer_files counts .qml and .js together, which is the set the README's "Files"
# column counts and the set the resolver below reads, so a count here says the
# direction rules are being applied to the tree the README describes. A count that
# rises because a file arrived is the count doing its job.
for layer in boot common features services; do
  t_true "the $layer/ layer directory exists" test -d "$SHELL_DIR/$layer"
done
t_true "the composition root shell.qml exists" test -f "$SHELL_DIR/shell.qml"
t_count "features/ holds the 148 files the README publishes" "148" "$(layer_files features)"
t_count "services/ holds the 26 files the README publishes" "26" "$(layer_files services)"
t_count "common/ holds the 127 files the README publishes" "127" "$(layer_files common)"
t_count "boot/ holds the 3 files the README publishes" "3" "$(layer_files boot)"
t_count "the composition root is the single file the README publishes" "1" "$(layer_files composition)"

t_section "every module sits inside one of the four layers, and every file inside one"
# The rule needs a closed set of layers. A .qml or .js that declares a module
# outside all four, or a file that belongs to no layer at all, would make every
# comparison below meaningless.
t_eq "every .qml and .js in the tree is in boot/ common/ features/ services/ or is shell.qml" \
  "0" "$(strays | wc -l | tr -d ' ')"
if [[ -n $(strays) ]]; then
  t_note "files in no layer:"$'\n'"$(strays)"
fi
rule "no resolved edge lands on a file that is in no layer" \
  '$6 != "external" && $7 == "stray"'
rule "no resolved edge leaves a file that is in no layer" \
  '$9 == "stray"'

# --------------------------------------------------------------------------
t_section "the resolver resolves every edge, not only the import lines"
t_not_empty "the tree has dependency edges to resolve" "$EDGES"
t_eq "no versioned import names a module no qmldir declares" \
  "0" "$(awk -F'\t' '$3 == "module" && $6 == "unknown-module"' "$WORK/resolved.tsv" | wc -l | tr -d ' ')"
t_eq "no relative import points at a file that is not there" \
  "0" "$(awk -F'\t' '($3 == "reljs" || $3 == "relqml") && $6 == "missing"' "$WORK/resolved.tsv" | wc -l | tr -d ' ')"
t_eq "no bare member reference reads through an alias that was never declared" \
  "0" "$(awk -F'\t' '$3 == "member" && $6 == "noalias"' "$WORK/resolved.tsv" | wc -l | tr -d ' ')"
t_note "$EDGES edges resolved: $(awk -F'\t' '{ print $3 "/" $6 }' "$WORK/resolved.tsv" | LC_ALL=C sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"

# --------------------------------------------------------------------------
t_section "common/ is the neutral layer: nothing but Qt/Quickshell and siblings"
# "common  ──►  nothing but Qt/Quickshell + sibling common code"
# must never: "import any other layer, relative or versioned"
rule "no common/ file imports qs.boot" '$9 == "common" && $7 == "boot"'
rule "no common/ file imports a qs.features module" '$9 == "common" && $7 == "features"'
rule "no common/ file imports a qs.services module" '$9 == "common" && $7 == "services"'
rule "no common/ file reaches outside common/ by relative path" \
  '$9 == "common" && ($3 == "reljs" || $3 == "relqml") && $7 != "common"'
# The rule above would also pass on a resolver that sees nothing, so the
# positive case is asserted too: common/ does read its own siblings.
t_true "common/ does read sibling common code, so the rule above is not vacuous" \
  test "$(awk -F'\t' '$9 == "common" && $7 == "common"' "$WORK/resolved.tsv" | wc -l)" -gt 0

# --------------------------------------------------------------------------
t_section "services/ never imports features/: the handoff count is zero"
# "services/ -> features/ is forbidden, because a service that calls into a
# feature has inverted the lifetime."
# "services/media/MediaEvents.qml -> qs.features.osd was the last such edge and
# the code no longer has it - the suite reports handoffs=0."
HANDOFFS="$(awk -F'\t' '$9 == "services" && $7 == "features"' "$WORK/resolved.tsv" | wc -l | tr -d ' ')"
t_note "handoffs=$HANDOFFS (services/ -> features/, every edge kind)"
t_eq "handoffs: no resolved services/ -> features/ edge" "0" "$HANDOFFS"
rule "no services/ file imports a qs.features module" \
  '$9 == "services" && $3 == "module" && $7 == "features"'
rule "no services/ file reads a member of a features module" \
  '$9 == "services" && $3 == "member" && $7 == "features"'
rule "no services/ file reaches into features/ by relative path" \
  '$9 == "services" && ($3 == "reljs" || $3 == "relqml") && $7 == "features"'
rule "MediaEvents.qml reaches no features layer, the edge the README calls the last one" \
  '$1 == "shell/services/media/MediaEvents.qml" && $7 == "features"'
# The mirror direction is real and legal, so the resolver is proved able to see
# the edge it is being forbidden from seeing in the other direction.
t_note "features/ -> services/ is real and legal: $(awk -F'\t' '$9 == "features" && $7 == "services" { print $1 }' "$WORK/resolved.tsv" | LC_ALL=C sort -u | wc -l | tr -d ' ') files do it"

# --------------------------------------------------------------------------
t_section "features/bar and features/wallpaper never import each other"
# "features/bar and features/wallpaper are mutually forbidden. They are both
# always-on per-output surfaces, and a cycle between them makes the startup
# order undecidable. They communicate through common/ instead."
rule "no features/bar file reaches features/wallpaper" \
  '$10 == "bar" && $8 == "wallpaper"'
rule "no features/wallpaper file reaches features/bar" \
  '$10 == "wallpaper" && $8 == "bar"'
rule "the forbidden pair is absent as a versioned import, a relative import and a member read" \
  '($10 == "bar" || $10 == "wallpaper") && ($8 == "bar" || $8 == "wallpaper") && $10 != $8'
# The handshake the two surfaces use instead: each reaches into common/ for
# what it needs from the other.
t_match "BarView.qml reads DesktopActions out of common/" \
  '\bDesktopActions\b' "$(cat "$SHELL_DIR/features/bar/BarView.qml")"
t_match "WallpaperView.qml reads DesktopLayoutState out of common/" \
  '\bDesktopLayoutState\b' "$(cat "$SHELL_DIR/features/wallpaper/WallpaperView.qml")"

# --------------------------------------------------------------------------
t_section "the bar demands its gated services itself and never names the catalog"
# features/bar/README.md, quoted. This section's rule is the feature's own
# rather than the one in shell/README.md the rest of this file restates:
#   "Bar.qml must carry an executable UnitGate.ensure and must not reference
#    qs.boot or BootRegistry"
# A feature that wants a gated service demands it itself; it never reaches into
# the catalog. The gate half is one call site, so the name alone is not it: the
# pattern wants the open paren and an argument, which a comment, a bare mention
# and a zero-argument call all fail. The reference half is a text scan rather
# than a direction rule, because `import qs.boot` already resolves to a boot
# edge that the features-wide rule above fails, while a bare `BootRegistry` read
# resolves to no edge at all - there is no import line for the resolver to find -
# so only a scan reaches it. The scan reads .qml and .js, the set the resolver
# reads too, so the README naming the forbidden names cannot fail its own gate.
t_match "Bar.qml carries an executable UnitGate.ensure call" \
  '\bUnitGate\.ensure\([^)]' "$(cat "$SHELL_DIR/features/bar/Bar.qml")"
BAR_CATALOG_REFS="$(grep -rn --include='*.qml' --include='*.js' -E '\b(qs\.boot|BootRegistry)\b' \
  "$SHELL_DIR/features/bar" | wc -l | tr -d ' ')"
t_note "features/bar names qs.boot or BootRegistry on $BAR_CATALOG_REFS line(s)"
t_eq "no features/bar file names qs.boot or BootRegistry" "0" "$BAR_CATALOG_REFS"
t_true "boot/ and shell.qml do name both, so the scan above is not vacuous" \
  test "$(grep -rl --include='*.qml' --include='*.js' -E '\b(qs\.boot|BootRegistry)\b' \
  "$SHELL_DIR/boot" "$SHELL_DIR/shell.qml" | wc -l)" -gt 0

# --------------------------------------------------------------------------
t_section "only boot/ (and shell.qml) may import every layer"
# "boot is the only thing allowed to import all layers" / "Only boot/ may
# import every layer. Boot is the composition root."
rule "no common/ file imports boot" '$9 == "common" && $7 == "boot"'
rule "no features/ file imports boot" '$9 == "features" && $7 == "boot"'
rule "no services/ file imports boot" '$9 == "services" && $7 == "boot"'
for layer in common features services; do
  t_true "boot/ really does reach $layer/, so the rule above is not vacuous" \
    test "$(awk -F'\t' -v l="$layer" '$9 == "boot" && $7 == l' "$WORK/resolved.tsv" | wc -l)" -gt 0
done

# --------------------------------------------------------------------------
t_section "boot is the composition root: it is never anyone's dependency"
# must never: "be imported by anything else"
rule "the only edge into the boot layer is boot/ reading its own module" \
  '$7 == "boot" && $9 != "boot" && $9 != "composition"'
t_eq "shell.qml, the composition root, is the one non-boot importer" \
  "1" "$(awk -F'\t' '$7 == "boot" && $9 != "boot"' "$WORK/resolved.tsv" | wc -l | tr -d ' ')"
t_eq "and it is shell.qml that reads it" \
  "shell/shell.qml" "$(awk -F'\t' '$7 == "boot" && $9 != "boot" { print $1 }' "$WORK/resolved.tsv" | LC_ALL=C sort -u)"
# A self-read inside boot/ is intra-module, not a dependency: BootRegistry is
# declared by qs.boot and referenced at Boot.qml:967, so the import at
# Boot.qml:31 is what makes the sibling visible. What must not exist is a boot
# edge onto a *different* module.
rule "no boot/ file imports a boot module other than its own" \
  '$9 == "boot" && $7 == "boot" && $3 == "module" && $4 != "qs.boot"'
t_note "boot/ reads its own module $(awk -F'\t' '$9 == "boot" && $7 == "boot" { printf "%s:%s (%s)\n", $1, $2, $4 }' "$WORK/resolved.tsv" | tr '\n' ' ')"

# --------------------------------------------------------------------------
t_section "the whole table in one derived fact: the set of cross-layer edges"
# boot -> common/features/services, features -> common/services,
# services -> common, composition -> boot. Nothing else, in either direction.
t_eq "the resolved cross-layer edge set is exactly the contract" \
  "boot -> common
boot -> features
boot -> services
composition -> boot
features -> common
features -> services
services -> common" \
  "$(awk -F'\t' '$6 != "external" && $9 != $7 { print $9 " -> " $7 }' "$WORK/resolved.tsv" | LC_ALL=C sort -u)"

# --------------------------------------------------------------------------
t_section "every .js under common/ that is a QML library keeps its layer"
# A .js that is not .pragma library is an ordinary script and cannot be
# .imported, so a common/ library reaching out is a dependency no import line
# records. The escape is checked, and the role is checked too: common/ is the
# layer other layers actually share code through, so "nothing leaves it" is a
# statement about a live boundary rather than an empty one.
rule "no common/ .js .imports a file outside common/" \
  '$9 == "common" && $3 == "reljs" && $7 != "common"'
t_true "common/ has .js libraries that do .import their siblings" \
  test "$(awk -F'\t' '$9 == "common" && $3 == "reljs" && $7 == "common"' "$WORK/resolved.tsv" | wc -l)" -gt 0
SHARED_JS="$(awk -F'\t' '$7 == "common" && $9 != "common" && $5 ~ /\.js$/' "$WORK/resolved.tsv" | wc -l | tr -d ' ')"
t_true "common/ is the shared library layer: other layers reach its .js files" \
  test "$SHARED_JS" -gt 0
t_note "$SHARED_JS cross-layer edges land on a .js under common/; all of them resolve to a real file"

t_summary
