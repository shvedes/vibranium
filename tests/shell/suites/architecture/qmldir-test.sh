#!/bin/bash
# Suite: qmldir - the module boundary contract.
#
# A qmldir is the only thing that makes a type a *module member*. Anything read
# through a module alias that the qmldir does not declare resolves to nothing
# at runtime and fails silently rather than loudly, so the check has to be
# made from the source rather than observed from a run.
#
# The rules under test, quoted:
#
#   shell/README.md:139  "46 `qmldir` files declare module boundaries
#                         (43 of them under `features/`)."
#   shell/README.md:140  "Anything read through a module alias
#                         (`import qs.features.menu as M` -> `M.animationsEnabled`)
#                         must be a member **declared in that module's
#                         `qmldir`**."
#   shell/README.md:142  "The architecture suite resolves the qualified read
#                         and fails on an undeclared one, because an
#                         undeclared member resolves to nothing at runtime
#                         and fails silently rather than loudly."
#   shell/README.md:146  "One trap this tree has already been bitten by:
#                         **`import QtQuick.Controls` must be aliased in
#                         wrappers**."
#   shell/README.md:147  "`common/qmldir` exports types named `ScrollBar`,
#                         `Button`, `CheckBox`, `Toggle` and `ProgressBar`, so
#                         an unaliased import makes the bare name resolve back
#                         to the shell's own wrapper."
#
# Five groups of assertions:
#
#   1. the qmldir files themselves - the two counts the README publishes, one
#      `module` line each, the `qs.` prefix, unique module names, entry
#      grammar, version, valid type names, no duplicate type name in one file;
#   2. every entry names a file that exists next to the qmldir, and that file
#      really provides the type (root object at column 0, file stem is the
#      type name, `pragma Singleton` in both directions);
#   3. the contract: every `Alias.member` read resolves to a name declared in
#      the alias's module - the assertion the README says this suite exists
#      for. An unaliased `import qs.<module>` is the same check with the module
#      left implicit, applied only where the providing module is unambiguous;
#   4. boot/Boot.qml, which imports many modules and reads through the
#      `Common.` and `Services.` aliases;
#   5. the README's named trap: the five control wrappers are declared in
#      `common/qmldir`, and nothing in the tree imports QtQuick.Controls
#      unaliased.
#
# No Quickshell is started and no qmllint is run: every claim here is a claim
# about the source, and the source is the whole of what a qmldir controls.
#
# Counts the README publishes are asserted exactly, as are the counts that
# describe the module surface. Counts that only describe how much code there
# is - how many reads the resolver happened to find - are guarded with "not
# zero" and reported in a note, because they move whenever a file is added and
# a boundary suite should not be red for that.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "qmldir" "module boundaries: the qmldir table, and every member read resolved through a declaration"

require_tools awk find sort grep sed mktemp comm wc cut tail tr

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-qmldir.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The two numbers shell/README.md:139 publishes.
DOC_QMLDIRS=46
DOC_FEATURES_QMLDIRS=43

# shell/README.md:147 - the wrapper names an unaliased QtQuick.Controls import
# would shadow.
WRAPPERS='ScrollBar Button CheckBox Toggle ProgressBar'

# count prints a line count with no leading whitespace, so a count assertion
# cannot be satisfied or broken by formatting.
count() { wc -l <"$1" | tr -d ' '; }

# --------------------------------------------------------------------------
# tables
# --------------------------------------------------------------------------

QMLDIRS="$WORK/qmldirs"
ENTRIES="$WORK/entries.tsv"
MODULE_MEMBER="$WORK/module-member.tsv"
QMLDIR_MODULE="$WORK/qmldir-module.tsv"
QML_FILES="$WORK/qml-files"

shell_qmldir_files >"$QMLDIRS"
[[ -s $QMLDIRS ]] || t_block "no qmldir file was found under $SHELL_DIR"
shell_qml_files >"$QML_FILES"
[[ -s $QML_FILES ]] || t_block "no .qml file was found under $SHELL_DIR"

# awk takes the file list as arguments, and the paths are held in an array
# rather than word-split so a checkout path with a space in it still works.
mapfile -t QMLDIR_LIST <"$QMLDIRS"

# ENTRIES: module, name, kind, version, relfile, dir, line - one row per entry,
#          with enough context to print a file:line diagnostic.
# MODULE_MEMBER: module, name - the membership table every resolution is made
#          against, so a resolution is checked against the qmldir text and not
#          against a value this suite computed twice.
# QMLDIR_MODULE: dir, module, qmldir path.
awk -v ent="$ENTRIES" -v mod="$MODULE_MEMBER" -v map="$QMLDIR_MODULE" '
  BEGIN { OFS = "\t" }
  FNR == 1 { dir = FILENAME; sub(/\/qmldir$/, "", dir); module = "" }
  /^module[[:space:]]/ {
    module = $2
    print dir, module, FILENAME > map
    next
  }
  NF {
    if ($1 == "singleton") { kind = "singleton"; name = $2; ver = $3; rel = $4 }
    else                    { kind = "type";      name = $1; ver = $2; rel = $3 }
    print module, name, kind, ver, rel, dir, FNR > ent
    print module, name > mod
  }
' "${QMLDIR_LIST[@]}"

# members_of prints the member list of a module.
members_of() {
  awk -F'\t' -v m="$1" '$1 == m { printf "%s ", $2 }' "$MODULE_MEMBER"
}

# module_dir maps a module name to the directory holding its qmldir.
module_dir() {
  awk -F'\t' -v m="$1" '$2 == m { print $1; exit }' "$QMLDIR_MODULE"
}

# at prints "<file>:<line>" for an entry, from its shell-relative qmldir.
at() { printf '%s:%s' "$(rel_to_shell "$1")/qmldir" "$2"; }

# --------------------------------------------------------------------------
# the resolver
# --------------------------------------------------------------------------
#
# One invocation per .qml file: argv[1] is the entries table, argv[2] the file
# under test. Comments and string-literal contents are blanked first, so a type
# name mentioned in prose is not mistaken for a read. `Name {`, `Name(` and
# `Name.member` are the three shapes a member reference takes.
#
# Records, pipe separated:
#   ALIAS        file line alias member module status reads
#   ALIASUNUSED  file 0 alias - module unused 0
#   IMPORTS      file 0 module - bare|alias 0        (what the file imports)
#   BARE         file line name module status          a type used as `Name {`
#   BAREQUAL     file line name module status          a type used as `Name.member`
#
# status:  ok          exactly one of the file's unaliased qs modules declares it
#          SIBLING     no module declares it; the implicit same-directory import does
#          AMBIG       two or more of the file's unaliased modules declare it
#          UNPROVIDED  nothing declares it and it is not a sibling
#          UNDECLARED  read through an alias, absent from that alias's module
#          unused      the alias is imported and never read
cat >"$WORK/resolve.awk" <<'RESOLVE_AWK'
BEGIN { FS = "\t"; OFS = "|" }
NR == FNR {
  member[$1] = member[$1] " " $2 " "
  owner[$2] = 1
  # The implicit same-directory import: a .qml beside another is reachable
  # unqualified from it, whether or not a qmldir declares it. Keyed on the
  # file's own directory, which is the qmldir's directory plus the entry's own
  # subdirectory, so a module member under ui/ is a sibling of ui/Button.qml
  # and not of common/Paths.qml.
  n = split($5, part, "/")
  base = part[n]
  sub(/\.qml$/, "", base)
  filedir = $6
  if (n > 1) {
    sub(/\/[^\/]*$/, "", $5)
    filedir = (filedir == "" ? "" : filedir "/") $5
  }
  stem[filedir, base] = 1
  next
}
{ lines[FNR] = strip($0) }
END {
  nlines = FNR
  selfdir = "."
  for (i = length(self); i > 0; i--) {
    if (substr(self, i, 1) == "/") { selfdir = substr(self, 1, i - 1); break }
  }
  for (k in stem) {
    split(k, kp, SUBSEP)
    if (kp[1] == selfdir) sib = sib " " kp[2] " "
  }

  # imports
  for (n = 1; n <= nlines; n++) {
    if (lines[n] !~ /^[ \t]*import[ \t]+/) continue
    s = lines[n]
    sub(/^[ \t]*import[ \t]+/, "", s)
    k = split(s, w, /[ \t]+/)
    if (w[2] == "as" && k >= 3 && w[1] ~ /^qs\./) {
      aliasmod[w[3]] = w[1]
      aliasline[w[3]] = n
      aliaslist[++nalias] = w[3]
      print "IMPORTS", self, n, w[1], w[3], "alias", 0
    } else if (k >= 1 && w[1] ~ /^qs\./) {
      baremod[w[1]] = 1
      print "IMPORTS", self, n, w[1], "-", "bare", 0
    }
  }

  # Alias.member reads
  for (ai = 1; ai <= nalias; ai++) {
    a = aliaslist[ai]
    re = "(^|[^A-Za-z0-9_.$])" a "\\.[A-Za-z_][A-Za-z0-9_]*"
    for (n = 1; n <= nlines; n++) {
      rest = lines[n]
      while (match(rest, re)) {
        st = RSTART; sl = RLENGTH
        mm = substr(rest, st, sl)
        if (match(mm, /\.[A-Za-z_][A-Za-z0-9_]*$/)) {
          mem = substr(mm, RSTART + 1, RLENGTH - 1)
          key = a "|" mem
          cnt[key]++
          if (!(key in fl)) fl[key] = n
        }
        rest = substr(rest, st + sl)
      }
    }
    hit = 0
    for (key in cnt) {
      if (index(key, a "|") != 1) continue
      hit = 1
      mem = key; sub(/^[^|]*\|/, "", mem)
      mod = aliasmod[a]
      ok = index(member[mod], " " mem " ") ? "ok" : "UNDECLARED"
      print "ALIAS", self, fl[key], a, mem, mod, ok, cnt[key]
    }
    if (!hit) print "ALIASUNUSED", self, aliasline[a], a, "-", aliasmod[a], "unused", 0
  }

  # Bare uses of a name that some qs module in the tree declares
  for (n = 1; n <= nlines; n++) {
    s = lines[n]
    while (match(s, /(^|[^A-Za-z0-9_.$])[A-Z][A-Za-z0-9_]*[ \t]*(\{|\()/)) {
      st = RSTART; sl = RLENGTH
      mm = substr(s, st, sl)
      if (match(mm, /[A-Za-z_][A-Za-z0-9_]*/)) {
        nm = substr(mm, RSTART, RLENGTH)
        if ((nm in owner) && !(nm in bseen)) { bseen[nm] = 1; bline[nm] = n }
      }
      s = substr(s, st + sl)
    }
    s = lines[n]
    while (match(s, /(^|[^A-Za-z0-9_.$])[A-Z][A-Za-z0-9_]*[ \t]*\.[A-Za-z_]/)) {
      st = RSTART; sl = RLENGTH
      mm = substr(s, st, sl)
      if (match(mm, /[A-Za-z_][A-Za-z0-9_]*/)) {
        nm = substr(mm, RSTART, RLENGTH)
        if ((nm in owner) && !(nm in qseen)) { qseen[nm] = 1; qline[nm] = n }
      }
      s = substr(s, st + sl)
    }
  }
  for (nm in bseen) report("BARE", nm, bline[nm])
  for (nm in qseen) report("BAREQUAL", nm, qline[nm])
}

function report(kind, nm, ln,   prov, m, ns, pp) {
  prov = ""
  for (m in baremod) if (index(member[m], " " nm " ")) prov = prov (prov == "" ? "" : ",") m
  if (prov != "") {
    ns = split(prov, pp, ",")
    if (ns == 1) { print kind, self, ln, nm, pp[1], "ok"; return }
    print kind, self, ln, nm, prov, "AMBIG"
    return
  }
  if (sib ~ ("(^| )" nm "( |$)")) { print kind, self, ln, nm, "sibling", "SIBLING"; return }
  print kind, self, ln, nm, "-", "UNPROVIDED"
}

# strip blanks comments and string-literal contents, so neither a commented out
# import nor a type name quoted in prose is read as code.
function strip(s,   out, i, c, n, q, blk) {
  out = ""; n = length(s); i = 1; q = ""; blk = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (blk) {
      if (c == "*" && substr(s, i + 1, 1) == "/") { blk = 0; i += 2; out = out " "; continue }
      i++
      continue
    }
    if (q != "") {
      if (c == "\\") { i += 2; continue }
      if (c == q) { q = ""; i++; out = out "\""; continue }
      i++
      continue
    }
    if (c == "\"" || c == "'") { q = c; i++; continue }
    if (c == "/" && substr(s, i + 1, 1) == "/") break
    if (c == "/" && substr(s, i + 1, 1) == "*") { blk = 1; i += 2; out = out " "; continue }
    out = out c
    i++
  }
  return out
}
RESOLVE_AWK

RESOLVED="$WORK/resolved.tsv"
: >"$RESOLVED"
while IFS= read -r qml; do
  awk -v self="$qml" -f "$WORK/resolve.awk" "$ENTRIES" "$qml" >>"$RESOLVED"
done <"$QML_FILES"

# --------------------------------------------------------------------------
# 1. the qmldir files
# --------------------------------------------------------------------------

t_section "the qmldir files and the module table"

QMLDIR_COUNT="$(count "$QMLDIRS")"
t_eq "the number of qmldir files (shell/README.md:139)" "$DOC_QMLDIRS" "$QMLDIR_COUNT"

FEATURE_QMLDIRS="$(awk -v root="$SHELL_DIR/features/" '
  FNR == 1 && index(FILENAME, root) == 1 { n++ } END { print n + 0 }' "${QMLDIR_LIST[@]}")"
t_eq "how many of them are under features/ (shell/README.md:139)" \
  "$DOC_FEATURES_QMLDIRS" "$FEATURE_QMLDIRS"

MODULE_LINES="$(awk 'FNR == 1 { if (NR > 1) total += n; n = 0 } /^module[[:space:]]/ { n++ } END { print total + n }' \
  "${QMLDIR_LIST[@]}")"
t_count "the number of \`module\` lines, one per qmldir" "$QMLDIR_COUNT" "$MODULE_LINES"

# A qmldir with no module line, or two, is a file the resolver cannot key on.
BAD_MODULE_LINES="$(awk '
  FNR == 1 { if (NR > 1 && n != 1) print prev ": " n " module line(s)"; prev = FILENAME; n = 0 }
  /^module[[:space:]]/ { n++ }
  END { if (n != 1) print prev ": " n " module line(s)" }' "${QMLDIR_LIST[@]}")"
t_eq "every qmldir declares exactly one module" "" "$BAD_MODULE_LINES"

MODULE_NAMES="$(cut -f2 "$QMLDIR_MODULE" | sort)"
t_sorted "the module names are reported in order" "$MODULE_NAMES"
t_count "distinct module names" "$QMLDIR_COUNT" \
  "$(printf '%s\n' "$MODULE_NAMES" | sort -u | wc -l | tr -d ' ')"
t_eq "every module name is in the qs. namespace" "" \
  "$(printf '%s\n' "$MODULE_NAMES" | grep -v '^qs\.' || true)"
t_unique "no module name is declared by two qmldirs" \
  "$(printf '%s\n' "$MODULE_NAMES" | sort | uniq -d)"

# --------------------------------------------------------------------------
# 2. the entries
# --------------------------------------------------------------------------

t_section "every entry is a declaration the engine can read"

ENTRY_COUNT="$(count "$ENTRIES")"
TYPE_COUNT="$(awk -F'\t' '$3 == "type"' "$ENTRIES" | wc -l | tr -d ' ')"
SINGLETON_COUNT="$(awk -F'\t' '$3 == "singleton"' "$ENTRIES" | wc -l | tr -d ' ')"
t_count "every entry is either a plain type or a singleton" "$ENTRY_COUNT" \
  "$((TYPE_COUNT + SINGLETON_COUNT))"
t_note "the module surface: $ENTRY_COUNT entries over $QMLDIR_COUNT modules - $TYPE_COUNT \
plain types and $SINGLETON_COUNT singletons, $(cut -f2 "$ENTRIES" | sort -u | wc -l | tr -d ' ') \
distinct type names"

# Grammar: `Type 1.0 File.qml` or `singleton Type 1.0 File.qml`, nothing else.
BAD_GRAMMAR="$(awk '
  FNR == 1 { q = FILENAME }
  /^module[[:space:]]/ { next }
  NF {
    if ($1 == "singleton") { if (NF != 4) print q ":" FNR ": " $0 }
    else                   { if (NF != 3) print q ":" FNR ": " $0 }
  }' "${QMLDIR_LIST[@]}")"
t_eq "every entry is \`Type Version File\` or \`singleton Type Version File\`" "" "$BAD_GRAMMAR"

BAD_VERSION="$(awk -F'\t' '$4 != "1.0" {
  printf "%s:%s: %s.%s declares version %s\n", $6, $7, $1, $2, $4 }' "$ENTRIES")"
t_eq "every entry declares version 1.0" "" "$BAD_VERSION"

BAD_NAME="$(awk -F'\t' '$2 !~ /^[A-Z][A-Za-z0-9]*$/ {
  printf "%s:%s: %s is not a QML type name\n", $6, $7, $2 }' "$ENTRIES")"
t_eq "every declared name is a QML type name (uppercase, alphanumeric)" "" "$BAD_NAME"

t_eq "no qmldir declares the same type name twice" "" \
  "$(awk -F'\t' '{ k = $1 SUBSEP $2; if (k in seen) print $1 "." $2; seen[k] = 1 }' "$ENTRIES" | sort -u)"

# --------------------------------------------------------------------------
# 3. the file each entry names
# --------------------------------------------------------------------------

t_section "every entry names a file that exists next to the qmldir and provides the type"

MISSING_FILES="$(while IFS=$'\t' read -r _e_mod e_name e_kind _e_ver e_rel e_dir e_line; do
  if [[ ! -f "$e_dir/$e_rel" || ! -r "$e_dir/$e_rel" ]]; then
    printf '%s: %s %s -> %s\n' "$(at "$e_dir" "$e_line")" "$e_kind" "$e_name" "$e_rel"
  fi
done <"$ENTRIES")"
t_eq "no entry names a file that is missing" "" "$MISSING_FILES"

NOT_QML="$(awk -F'\t' '$5 !~ /\.qml$/ {
  printf "%s:%s: %s -> %s\n", $6, $7, $2, $5 }' "$ENTRIES")"
t_eq "every entry names a .qml file" "" "$NOT_QML"

# A QML type is declared by the file that holds it: the root object, which the
# language requires to sit at column 0, whether `Item {`, `PanelWindow {` or
# `Singleton {`.
NO_ROOT="$(while IFS=$'\t' read -r _e_mod e_name e_kind _e_ver e_rel e_dir e_line; do
  if ! awk '/^[A-Za-z_][A-Za-z0-9_]*[ \t]*\{/ { found = 1; exit } END { exit(found ? 0 : 1) }' \
    "$e_dir/$e_rel"; then
    printf '%s: %s %s -> %s declares no root object\n' "$(at "$e_dir" "$e_line")" \
      "$e_kind" "$e_name" "$e_rel"
  fi
done <"$ENTRIES")"
t_eq "every declared file declares a root object" "" "$NO_ROOT"

# The file's stem is the type's name. A qmldir may rename it, and this tree
# does that once on purpose - state/State.qml is exported as AppState because
# ShellState, ShellCache and DesktopLayoutState are the facades over it - so
# the set of renames is pinned rather than forbidden.
RENAMES="$WORK/renames.txt"
awk -F'\t' '{
  n = split($5, part, "/")
  stem = part[n]
  sub(/\.qml$/, "", stem)
  if (stem != $2) print $1 " " $2 " <- " $5
}' "$ENTRIES" | sort >"$RENAMES"
t_lines "the entries whose name differs from the file stem" "1" "$(count "$RENAMES")" \
  "$(cat "$RENAMES")"
t_eq "and it is the one deliberate rename" \
  "qs.common AppState <- state/State.qml" "$(cat "$RENAMES")"

# --------------------------------------------------------------------------
# 4. singleton and the keyword
# --------------------------------------------------------------------------

t_section "the \`singleton\` keyword and \`pragma Singleton\` agree, in both directions"

MISSING_PRAGMA="$WORK/singleton-missing-pragma.txt"
: >"$MISSING_PRAGMA"
while IFS=$'\t' read -r _e_mod e_name e_kind _e_ver e_rel e_dir e_line; do
  [[ $e_kind == singleton ]] || continue
  grep -q '^pragma Singleton' "$e_dir/$e_rel" ||
    printf '%s: %s is declared singleton but %s has no `pragma Singleton`\n' \
      "$(at "$e_dir" "$e_line")" "$e_name" "$e_rel" >>"$MISSING_PRAGMA"
done <"$ENTRIES"
t_eq "every \`singleton\` entry's file has \`pragma Singleton\`" \
  "" "$(cat "$MISSING_PRAGMA")"

# The other direction is the one that fails at runtime: a `pragma Singleton`
# file declared without the keyword is constructed per use instead of once.
EXTRA_PRAGMA="$WORK/plain-declared-pragma.txt"
: >"$EXTRA_PRAGMA"
while IFS=$'\t' read -r _e_mod e_name e_kind _e_ver e_rel e_dir e_line; do
  [[ $e_kind == singleton ]] && continue
  if grep -q '^pragma Singleton' "$e_dir/$e_rel"; then
    printf '%s: %s is declared without `singleton` but %s has `pragma Singleton`\n' \
      "$(at "$e_dir" "$e_line")" "$e_name" "$e_rel" >>"$EXTRA_PRAGMA"
  fi
done <"$ENTRIES"
t_eq "no \`pragma Singleton\` file is declared without the \`singleton\` keyword" \
  "" "$(cat "$EXTRA_PRAGMA")"

# And the same thing from the file side: nothing carries `pragma Singleton`
# without being a `singleton` entry somewhere, so the two sets are identical.
PRAGMA_FILES="$WORK/pragma-files.txt"
grep -rln '^pragma Singleton' --include='*.qml' "$SHELL_DIR" | sed "s|^$SHELL_DIR/||" \
  | sort >"$PRAGMA_FILES"
SINGLETON_FILES="$WORK/singleton-files.txt"
awk -F'\t' '$3 == "singleton" { print $6 "/" $5 }' "$ENTRIES" | sed "s|^$SHELL_DIR/||" \
  | sort -u >"$SINGLETON_FILES"
t_eq "every file with \`pragma Singleton\` is a \`singleton\` entry, and the reverse" \
  "" "$(comm -3 "$PRAGMA_FILES" "$SINGLETON_FILES")"
t_note "$(count "$PRAGMA_FILES") files carry \`pragma Singleton\`; three of them \
(screenshots/Screenshots, privacy/Privacy, weather/Weather) are declared by two modules \
each, so $(( $(count "$SINGLETON_FILES") + 3 )) singleton entries name $(count "$SINGLETON_FILES") files"

# Every .qml beside a qmldir is declared in it, so a component cannot sit in a
# module directory and be reachable only by accident.
UNDECLARED_SIBLINGS="$WORK/undeclared-siblings.txt"
: >"$UNDECLARED_SIBLINGS"
for dir in $(cut -f1 "$QMLDIR_MODULE" | sort -u); do
  for f in "$dir"/*.qml; do
    [[ -e $f ]] || continue
    if ! awk -v want="$(basename "$f")" '$NF == want { found = 1; exit } END { exit(found ? 0 : 1) }' \
      "$dir/qmldir"; then
      printf '%s is not declared in %s\n' "$(rel_to_shell "$f")" \
        "$(rel_to_shell "$dir")/qmldir" >>"$UNDECLARED_SIBLINGS"
    fi
  done
done
t_eq "no .qml sits in a module directory without being declared" \
  "" "$(cat "$UNDECLARED_SIBLINGS")"

# --------------------------------------------------------------------------
# 5. the contract: a read through an alias
# --------------------------------------------------------------------------

t_section "every member read through an alias is declared in that module"

ALIAS_RECORDS="$WORK/alias-records.tsv"
awk -F'|' '$1 == "ALIAS"' "$RESOLVED" | sort >"$ALIAS_RECORDS"
ALIAS_READS="$(awk -F'|' '{ n += $8 } END { print n + 0 }' "$ALIAS_RECORDS")"
ALIAS_SITES="$(awk -F'|' '{ print $2 "|" $4 "|" $6 }' "$ALIAS_RECORDS" | sort -u | wc -l | tr -d ' ')"
ALIAS_FILES="$(cut -d'|' -f2 "$ALIAS_RECORDS" | sort -u | wc -l | tr -d ' ')"
ALIAS_IMPORTS="$(awk -F'|' '$1 == "IMPORTS" && $6 == "alias"' "$RESOLVED" | wc -l | tr -d ' ')"
t_ne "the resolver found member reads through an alias" "0" "$ALIAS_READS"
t_count "the tree has 31 aliased \`import qs.* as Alias\` lines" "31" "$ALIAS_IMPORTS"
t_note "$ALIAS_READS reads through $ALIAS_SITES alias/module pairs, across $ALIAS_FILES files; \
$((ALIAS_IMPORTS - ALIAS_SITES)) of the $ALIAS_IMPORTS aliased imports is never read"

# The assertion the README says this suite exists for. One failing assertion per
# hit, so an undeclared member is reported as file:line, alias, member and the
# module that was expected - not as a count.
UNRESOLVED="$WORK/alias-undeclared.tsv"
awk -F'|' '$7 == "UNDECLARED" { print $2 "|" $3 "|" $4 "|" $5 "|" $6 }' "$ALIAS_RECORDS" \
  >"$UNRESOLVED"
while IFS='|' read -r u_file u_line u_alias u_member u_module; do
  [[ -n $u_file ]] || continue
  t_contains "$(rel_to_shell "$u_file"):$u_line reads $u_alias.$u_member, declared in $u_module" \
    "$u_member" "$(members_of "$u_module")"
done <"$UNRESOLVED"
t_eq "no aliased member read is undeclared" "0" "$(count "$UNRESOLVED")"

# An alias nothing reads is dead weight rather than a broken boundary, but it is
# the shape a copy-pasted import takes, so it is named.
UNUSED_ALIASES="$(awk -F'|' -v root="$SHELL_DIR/" '$1 == "ALIASUNUSED" {
  f = $2; sub("^" root, "", f)
  printf "%s:%s imports %s as %s and never reads a member of it", f, $3, $6, $4 }' "$RESOLVED")"
t_note "aliased imports with no member read: ${UNUSED_ALIASES:-none}"

# Every module named by an import has to exist, or the file is reading through
# a namespace that was never declared.
DECLARED_MODULES="$WORK/declared-modules.txt"
cut -f2 "$QMLDIR_MODULE" | sort -u >"$DECLARED_MODULES"
IMPORTED_MODULES="$WORK/imported-modules.txt"
: >"$IMPORTED_MODULES"
for kind in bare alias; do
  IMPORT_SITES="$WORK/import-$kind-sites.tsv"
  awk -F'|' -v k="$kind" '$1 == "IMPORTS" && $6 == k' "$RESOLVED" | sort >"$IMPORT_SITES"
  t_ne "the tree has $kind \`import qs.<module>\` lines" "0" "$(count "$IMPORT_SITES")"
  cut -d'|' -f4 "$IMPORT_SITES" | sort -u >>"$IMPORTED_MODULES"
  t_eq "no $kind \`import qs.<module>\` names a module that no qmldir declares" "" \
    "$(cut -d'|' -f4 "$IMPORT_SITES" | sort -u | comm -23 - "$DECLARED_MODULES")"
done
sort -u -o "$IMPORTED_MODULES" "$IMPORTED_MODULES"

# A relative import is the other way in, and every one must be a .js library
# rather than a directory: a directory import would sidestep the qmldir.
RELATIVE_NONJS="$WORK/relative-nonjs.txt"
while IFS= read -r qml; do
  sed -n 's/^[[:space:]]*import[[:space:]]*"\([^"]*\)".*/\1/p' "$qml"
done <"$QML_FILES" | grep -v '\.js$' | sort -u >"$RELATIVE_NONJS"
t_eq "every relative import is a .js library, not a directory" "" "$(cat "$RELATIVE_NONJS")"

# --------------------------------------------------------------------------
# 6. the contract: a bare member use from an unaliased import
# --------------------------------------------------------------------------

t_section "a bare use resolves to exactly one unaliased module, or is reported"

BARE_OK="$(awk -F'|' '$1 == "BARE" && $6 == "ok"' "$RESOLVED" | wc -l | tr -d ' ')"
BAREQUAL_OK="$(awk -F'|' '$1 == "BAREQUAL" && $6 == "ok"' "$RESOLVED" | wc -l | tr -d ' ')"
BARE_SIBLING="$(awk -F'|' '$1 == "BARE" && $6 == "SIBLING"' "$RESOLVED" | wc -l | tr -d ' ')"
BAREQUAL_SIBLING="$(awk -F'|' '$1 == "BAREQUAL" && $6 == "SIBLING"' "$RESOLVED" | wc -l | tr -d ' ')"
t_ne "bare type uses resolved through an unaliased module" "0" "$BARE_OK"
t_ne "bare qualified uses (Name.member) resolved through an unaliased module" "0" "$BAREQUAL_OK"
t_note "$BARE_OK \`Name {\` uses and $BAREQUAL_OK \`Name.member\` uses each resolve to one \
module; $((BARE_SIBLING + BAREQUAL_SIBLING)) more are supplied by the implicit \
same-directory import, which the module contract does not cover"

# Where two unaliased modules of the same file declare the name, the bare use
# is genuinely ambiguous and guessing would be worse than saying so.
AMBIGUOUS="$WORK/ambiguous.tsv"
awk -F'|' '($1 == "BARE" || $1 == "BAREQUAL") && $6 == "AMBIG"' "$RESOLVED" \
  | sort >"$AMBIGUOUS"
t_eq "no bare use is left ambiguous by two unaliased modules" "0" "$(count "$AMBIGUOUS")"
while IFS='|' read -r a_kind a_file a_line a_name a_mods _a_status; do
  [[ $a_kind == BARE || $a_kind == BAREQUAL ]] || continue
  t_note "skipped, ambiguous: $(rel_to_shell "$a_file"):$a_line uses $a_name, which $a_mods all declare"
done <"$AMBIGUOUS"

# A bare use that no module declares and no sibling provides is either a Qt
# type or a missing import, and a source pass cannot tell those apart without a
# type registry. In this tree the whole set is one name.
UNPROVIDED="$WORK/unprovided.tsv"
awk -F'|' '($1 == "BARE" || $1 == "BAREQUAL") && $6 == "UNPROVIDED"' "$RESOLVED" \
  | sort >"$UNPROVIDED"
UNPROVIDED_NAMES="$(cut -d'|' -f4 "$UNPROVIDED" | sort -u | tr '\n' ' ')"
# A source pass cannot separate a Qt type from a missing import without a type
# registry, so this set cannot simply be asserted empty. It can be pinned: the
# only name in it is the QtQuick Timer, so a new one is a bare read that no
# module provides - a missing import - and fails here rather than in a note.
t_eq "the only bare use no qs module and no sibling declares is the QtQuick Timer" \
  "Timer " "$UNPROVIDED_NAMES"
t_note "$(count "$UNPROVIDED") bare \`Timer\` uses, in files that import neither qs.services \
nor qs.features.bar.modules.Timer unaliased, so the bare name is the QtQuick one"

# Timer is a QtQuick type and it is also declared by qs.services and by
# qs.features.bar.modules.Timer, so a bare `Timer` in a file that imports either
# unaliased would resolve to the shell's own Timer. That is the controls-wrapper
# trap with a different control, so it is checked rather than assumed.
TIMER_SHADOW_MODULES='qs.services|qs.features.bar.modules.Timer'
TIMER_SHADOWED="$WORK/timer-shadowed.txt"
awk -F'|' -v mods="$TIMER_SHADOW_MODULES" '
  $1 == "IMPORTS" && $6 == "bare" && $4 ~ "^(" mods ")$" { imports[$2] = 1; next }
  $1 == "BARE" && $4 == "Timer" && $6 == "UNPROVIDED" { if ($2 in imports) print $2 " " $3 }
' "$RESOLVED" | sort -u >"$TIMER_SHADOWED"
t_eq "no bare \`Timer\` is shadowed by an unaliased qs.services or bar Timer import" \
  "" "$(cat "$TIMER_SHADOWED")"

# --------------------------------------------------------------------------
# 7. boot/Boot.qml, the composition root
# --------------------------------------------------------------------------

t_section "boot/Boot.qml reads through Common. (Services. lives in BootLate.qml)"

BOOT_QML="$SHELL_DIR/boot/Boot.qml"
t_file "boot/Boot.qml exists" "$BOOT_QML"
BOOT_ALIASES="$(awk -F'|' -v b="$BOOT_QML" '$1 == "IMPORTS" && $2 == b && $6 == "alias" { print $5 }' \
  "$RESOLVED" | sort -u | tr '\n' ' ')"
t_eq "the aliases Boot.qml imports" "Common " "$BOOT_ALIASES"
BOOT_READS="$WORK/boot-reads.tsv"
awk -F'|' -v b="$BOOT_QML" '$1 == "ALIAS" && $2 == b' "$RESOLVED" | sort >"$BOOT_READS"
t_ne "Boot.qml reads members through its aliases" "0" "$(count "$BOOT_READS")"
t_note "Boot.qml: $(awk -F'|' '{ printf "%s.%s ", $4, $5 }' "$BOOT_READS")"
while IFS='|' read -r _b_kind b_file b_line b_alias b_member b_module _b_status _b_reads; do
  [[ -n $b_file ]] || continue
  t_contains "Boot.qml:$b_line $b_alias.$b_member is declared in $b_module" \
    "$b_member" "$(members_of "$b_module")"
done <"$BOOT_READS"

# --------------------------------------------------------------------------
# 8. the named trap
# --------------------------------------------------------------------------

t_section "the control wrappers the README calls out"

t_eq "qs.common's qmldir is common/qmldir" "$SHELL_DIR/common" "$(module_dir qs.common)"
for wrapper in $WRAPPERS; do
  t_count "common/qmldir declares $wrapper exactly once" "1" \
    "$(awk -F'\t' -v n="$wrapper" '$1 == "qs.common" && $2 == n' "$ENTRIES" | wc -l | tr -d ' ')"
  t_file "the $wrapper wrapper file exists" \
    "$SHELL_DIR/common/ui/$wrapper.qml"
done

# The trap itself: an unaliased QtQuick.Controls import makes the bare name
# resolve back to the shell's own wrapper, silently.
CONTROLS_IMPORTS="$WORK/controls-imports.txt"
UNALIASED_CONTROLS="$WORK/controls-unaliased.txt"
: >"$CONTROLS_IMPORTS"
: >"$UNALIASED_CONTROLS"
while IFS= read -r qml; do
  while IFS= read -r hit; do
    printf '%s:%s\n' "$(rel_to_shell "$qml")" "${hit%%:*}" >>"$CONTROLS_IMPORTS"
  done < <(grep -nE '^[[:space:]]*import[[:space:]]*QtQuick\.Controls[[:space:]]*($|as[[:space:]])' "$qml" || true)
done <"$QML_FILES"
while IFS= read -r loc; do
  if ! grep -qE '^[[:space:]]*import[[:space:]]*QtQuick\.Controls[[:space:]]+as[[:space:]]' "${SHELL_DIR}/${loc%:*}"; then
    printf '%s\n' "$loc" >>"$UNALIASED_CONTROLS"
  fi
done <"$CONTROLS_IMPORTS"
t_eq "no .qml imports QtQuick.Controls unaliased" "" "$(cat "$UNALIASED_CONTROLS")"
t_note "the files that do import QtQuick.Controls, all of them aliased: $(sort "$CONTROLS_IMPORTS" | tr '\n' ' ')"

t_note "declared but never imported: $(comm -13 "$IMPORTED_MODULES" "$DECLARED_MODULES" | tr '\n' ' ')- each \
re-exports a name the parent module already declares, so nothing needs them and nothing breaks"

# Cosmetic: a qmldir whose last line has no newline still parses, but the next
# append will produce a joined line. Not the contract, so it is only recorded.
NO_FINAL_NEWLINE="$(while IFS= read -r qd; do
  if [[ -n "$(tail -c 1 "$qd")" ]]; then printf '%s ' "$(rel_to_shell "$qd")"; fi
done <"$QMLDIRS")"
t_note "qmldirs with no newline at end of file: ${NO_FINAL_NEWLINE:-none}"

t_summary
