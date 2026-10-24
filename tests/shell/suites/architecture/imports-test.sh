#!/bin/bash
# Suite: imports - every dependency edge in shell/ resolves to something real.
#
# Companion to layers-test.sh, which decides which directions are legal. This
# suite decides whether an edge exists at all. The two together answer the two
# questions the shell README treats as separately worth failing on:
#
#   "Every one of those rules is executable, not aspirational"      -> layers
#   "49 qmldir files declare module boundaries (43 of them under
#    features/). Anything read through a module alias (import
#    qs.features.menu as M -> M.animationsEnabled) must be a member
#    declared in that module's qmldir."                             -> here
#
#   "One trap this tree has already been bitten by: import
#    QtQuick.Controls must be aliased in wrappers. common/qmldir exports
#    types named ScrollBar, Button, CheckBox, Toggle and ProgressBar, so an
#    unaliased import makes the bare name resolve back to the shell's own
#    wrapper. It is silent - no error, no warning - and the result is a
#    control with none of the native behaviour."
#
# Nothing here needs a live Quickshell, and nothing here needs qmllint: a
# separate suite owns linting. qmllint is used at the very end as a recorded
# cross-check only, and its absence changes nothing.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "imports" "every import, module entry and alias in shell/ resolves"
require_tools awk find sort

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-imports.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------
# 1. Read every qmldir: its module line, and every type entry it declares.
#
# A qmldir entry is `Type 1.0 File.qml` or `singleton Type 1.0 File.qml`; the
# version is the field before the filename either way. Anything else on a
# non-comment line is a directive, recorded separately so it cannot be
# mistaken for an entry.
# --------------------------------------------------------------------------
cat >"$WORK/qmldir.awk" <<'AWK'
FNR == 1 {
  p = index(FILENAME, root)
  d = (p == 1) ? "shell/" substr(FILENAME, length(root) + 1) : FILENAME
  sub(/\/[^\/]*$/, "", d)
  mod = ""; seen = 0
}
{
  ln = FNR
  line = $0
  sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
  if (line == "" || line ~ /^#/) next
  if (line ~ /^module([ \t]|$)/) {
    mod = line; sub(/^module[ \t]+/, "", mod); sub(/[ \t]+$/, "", mod)
    seen = 1
    printf "MOD\t%s\t%s\t%s\n", d, mod, ln
    next
  }
  if (seen != 1) {
    printf "BEFORE\t%s\t%s\t%s\n", d, mod, line
    next
  }
  nf = split(line, f, /[ \t]+/)
  if (nf == 4 && (f[1] == "singleton" || f[1] == "internal" || f[1] == "optional")) {
    printf "ENT\t%s\t%s\t%s\t%s\t%s\t%s\n", d, f[2], f[3], f[4], ln, mod
  } else if (nf == 3) {
    printf "ENT\t%s\t%s\t%s\t%s\t%s\n", d, f[1], f[2], f[3], ln, mod
  } else {
    printf "DIR\t%s\t%s\t%s\t%s\n", d, mod, ln, line
  }
}
AWK

while IFS= read -r qmldir; do printf '%s\n' "$qmldir"; done < <(shell_qmldir_files) |
  xargs -r awk -v root="$SHELL_DIR/" -f "$WORK/qmldir.awk" >"$WORK/qmldirs.tsv"

# --------------------------------------------------------------------------
# 2. The edges. The same four kinds layers-test.sh resolves, so the two suites
#    cannot disagree about what an edge is:
#       module  `import qs.x [as A]`  relqml `import "p"` in a .qml
#       reljs   `.import "p"` in a .js           member `A.member`
# --------------------------------------------------------------------------
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

# 3. Existence, so a resolved path can be checked against the tree.
find "$SHELL_DIR" -type f -printf '%P\n' | sed 's|^|shell/|' | LC_ALL=C sort >"$WORK/files.txt"

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
  printf "%s\t%d\t%s\t%s\t%s\t%s\n", \
    src, ln, kind, (kind == "member" ? d4 "." d5 : d4), target, tkind
}
AWK

mapfile -t SOURCES < <(
  { find "$SHELL_DIR" -name '*.qml' -type f; find "$SHELL_DIR" -name '*.js' -type f; } |
    LC_ALL=C sort
)
awk -v root="$SHELL_DIR/" -v aliasfile="$WORK/aliases.tsv" \
  -f "$WORK/scan.awk" "${SOURCES[@]}" >"$WORK/edges.tsv"
awk -F'\t' '$1 == "MOD" { printf "%s\t%s\n", $3, $2 }' "$WORK/qmldirs.tsv" |
  LC_ALL=C sort -u >"$WORK/modules.tsv"
awk -F'\t' -v modfile="$WORK/modules.tsv" -v alfile="$WORK/aliases.tsv" \
  -v exfile="$WORK/files.txt" -f "$WORK/join.awk" "$WORK/edges.tsv" \
  >"$WORK/resolved.tsv"

# resolved.tsv fields: 1 source  2 line  3 kind  4 detail  5 target  6 how

# zero <label> <awk-expr> - fails with the offending records named.
zero() {
  local label="$1" expr="$2" hits n
  hits="$(awk -F'\t' "$expr" "$WORK/resolved.tsv")"
  n="$(printf '%s' "$hits" | wc -l | tr -d ' ')"
  t_eq "$label" "0" "$n"
  if [[ $n != 0 ]]; then
    t_note "offenders for \"$label\":"$'\n'"$hits"
  fi
}

# --------------------------------------------------------------------------
t_section "the qmldir declaration contract belongs to qmldir-test.sh"
# The module table, entry grammar, entry versions, and the agreement between
# a `singleton` entry and a `pragma Singleton` file are all declared
# properties of the qmldir files, and they are asserted once, in
# qmldir-test.sh. This suite reads the module table because it has to, to
# resolve an import, but it does not re-assert what the table should contain -
# two suites claiming one contract means a fix has to be found twice and a
# regression can hide in the one nobody runs.
t_note "qmldir grammar, versions, singleton agreement and aliased member reads are asserted in qmldir-test.sh"
t_note "this suite owns import resolution: module edges, relative edges, the QtQuick.Controls trap"

# --------------------------------------------------------------------------
t_section "every import qs.<x> names a module a qmldir in the tree declares"
zero "no versioned import names an undeclared module" '$3 == "module" && $6 == "unknown-module"'
t_eq "every module edge is either a declared qs.* module or a Qt/Quickshell module" \
  "0" "$(awk -F'\t' '$3 == "module" && $6 == "external" && $4 !~ /^Qt[.A-Z]/ && $4 !~ /^Quickshell([.]|$)/' "$WORK/resolved.tsv" | wc -l | tr -d ' ')"
t_eq "no qs.* module is imported that the tree does not declare" \
  "0" "$(comm -13 \
      <(awk -F'\t' '$1 == "MOD" { print $3 }' "$WORK/qmldirs.tsv" | LC_ALL=C sort) \
      <(awk -F'\t' '$3 == "module" && $4 ~ /^qs\./ { print $4 }' "$WORK/resolved.tsv" | LC_ALL=C sort -u) |
    wc -l | tr -d ' ')"
DECLARED="$(awk -F'\t' '$1 == "MOD"' "$WORK/qmldirs.tsv" | wc -l | tr -d ' ')"
IMPORTED="$(awk -F'\t' '$3 == "module" && $4 ~ /^qs\./ { print $4 }' "$WORK/resolved.tsv" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
t_note "$IMPORTED of the $DECLARED declared modules are named by an import; a module nobody imports is a boundary, not a broken edge"
t_note "edges by kind: $(awk -F'\t' '{ print $3 "/" $6 }' "$WORK/resolved.tsv" | LC_ALL=C sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"

# --------------------------------------------------------------------------
t_section "every relative import resolves to a real file"
# A .js reached by a relative import that does not exist, or that is not a
# .pragma library, is a silent failure: the name resolves to nothing at
# runtime rather than raising.
zero "no .js .import points at a file that is not there" '$3 == "reljs" && $6 == "missing"'
zero "no .qml relative import points at a file that is not there" '$3 == "relqml" && $6 == "missing"'
NOT_LIBRARY=0
NOT_LIBRARY_LIST=""
mapfile -t JS_TARGETS < <(awk -F'\t' '$3 == "reljs" { print $5 }' "$WORK/resolved.tsv" | LC_ALL=C sort -u)
for target in "${JS_TARGETS[@]}"; do
  if [[ -n $target && $target != "-" ]] && ! grep -q '^\.pragma library' "$SHELL_DIR/${target#shell/}"; then
    NOT_LIBRARY=$((NOT_LIBRARY + 1))
    NOT_LIBRARY_LIST+="$target"$'\n'
  fi
done
t_eq "every .js .import target declares .pragma library" "0" "$NOT_LIBRARY"
if ((NOT_LIBRARY > 0)); then
  t_note "imported without .pragma library:"$'\n'"${NOT_LIBRARY_LIST%$'\n'}"
fi
# "Every .pragma library JS that a .qml file .imports resolves to a real file."
# In this tree that set is empty: a .qml reaches a library through a
# directory-relative `import "x.js"`, which is checked above. Recorded rather
# than asserted vacuously.
t_eq "no .qml file uses the .import form" \
  "0" "$(awk -F'\t' '$3 == "reljs" && $1 ~ /\.qml$/' "$WORK/resolved.tsv" | wc -l | tr -d ' ')"
t_note "the .qml-to-library edge is the directory-relative form instead: $(awk -F'\t' '$3 == "relqml"' "$WORK/resolved.tsv" | wc -l | tr -d ' ') of them, all resolved"
t_true "and at least one library is reached that way" \
  test "$(awk -F'\t' '$3 == "relqml"' "$WORK/resolved.tsv" | wc -l)" -gt 0

# --------------------------------------------------------------------------
t_section "a member read resolves through its alias to a module that exists"
# "import qs.features.menu as M -> M.animationsEnabled must be a member
#  declared in that module's qmldir." Whether the member IS declared is
#  asserted in qmldir-test.sh, which owns that contract and reports the
#  offending file:line. What belongs here is the edge itself: the alias must
#  have come from an import, and that import's module must resolve. A member
#  read through an alias nothing declared is a resolution failure, not a
# declaration failure, and only this suite can see the alias.
zero "no member read goes through an alias no import declared" '$3 == "member" && $6 == "noalias"'
zero "no member read goes through an alias whose module is undeclared" '$3 == "member" && $6 == "unknown-module"'
t_true "the tree does read members through module aliases" \
  test "$(awk -F'\t' '$3 == "member" && $6 == "module"' "$WORK/resolved.tsv" | wc -l)" -gt 0
t_note "$(awk -F'\t' '$3 == "member" && $6 == "module"' "$WORK/resolved.tsv" | wc -l | tr -d ' ') member reads through module aliases, all resolved; qmldir-test.sh asserts each is declared"

# --------------------------------------------------------------------------
t_section "the QtQuick.Controls trap: aliased everywhere, and used"
# "import QtQuick.Controls must be aliased in wrappers. common/qmldir exports
#  types named ScrollBar, Button, CheckBox, Toggle and ProgressBar, so an
#  unaliased import makes the bare name resolve back to the shell's own
#  wrapper. It is silent."
UNALIASED="$(grep -rnE '^[[:space:]]*import[[:space:]]+QtQuick\.Controls[[:space:]]*$' \
  --include='*.qml' --include='*.js' "$SHELL_DIR" || true)"
t_eq "no file in the tree imports QtQuick.Controls unaliased" \
  "0" "$(printf '%s' "$UNALIASED" | grep -c '' || true)"
if [[ -n $UNALIASED ]]; then
  t_note "unaliased imports:"$'\n'"${UNALIASED//$SHELL_DIR\//}"
fi
mapfile -t CTL_FILES < <(grep -rlE '^[[:space:]]*import[[:space:]]+QtQuick\.Controls[[:space:]]+as[[:space:]]' \
  --include='*.qml' --include='*.js' "$SHELL_DIR" | LC_ALL=C sort)
t_not_empty "the tree does import QtQuick.Controls, so the rule is exercised" "${CTL_FILES[*]}"
t_eq "every file that imports QtQuick.Controls aliases it" \
  "${#CTL_FILES[@]}" "$(grep -rlE '^[[:space:]]*import[[:space:]]+QtQuick\.Controls' \
    --include='*.qml' --include='*.js' "$SHELL_DIR" | wc -l | tr -d ' ')"
OUTSIDE_COMMON=0
OUTSIDE_LIST=""
for f in "${CTL_FILES[@]}"; do
  case "$f" in
    "$SHELL_DIR"/common/*) ;;
    *) OUTSIDE_COMMON=$((OUTSIDE_COMMON + 1)); OUTSIDE_LIST+="$(rel_to_shell "$f")"$'\n' ;;
  esac
done
t_eq "every QtQuick.Controls importer is one of the shell/common/ wrappers" "0" "$OUTSIDE_COMMON"
if ((OUTSIDE_COMMON > 0)); then
  t_note "importers outside shell/common/:"$'\n'"${OUTSIDE_LIST%$'\n'}"
fi
# The wrapper names the README names must really be exported, or the trap
# would not exist.
for wrapper in ScrollBar Button CheckBox Toggle ProgressBar; do
  t_true "qs.common exports $wrapper, the colliding name the README names" \
    awk -F'\t' -v t="$wrapper" '$1 == "ENT" && $2 == "shell/common" && $3 == t { found = 1 }
      END { exit !found }' "$WORK/qmldirs.tsv"
done
# And the alias has to be used, or aliasing it is decoration.
t_note "aliases used for QtQuick.Controls: $(grep -rhoE '^[[:space:]]*import[[:space:]]+QtQuick\.Controls[[:space:]]+as[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
  --include='*.qml' "$SHELL_DIR" | awk '{ print $NF }' | LC_ALL=C sort -u | tr '\n' ' ')"
CTL_ALIAS_UNUSED=0
CTL_ALIAS_LIST=""
for f in "${CTL_FILES[@]}"; do
  alias_name="$(awk '
    /^[[:space:]]*import[[:space:]]+QtQuick\.Controls[[:space:]]+as[[:space:]]/ {
      a = $0
      sub(/^.*[[:space:]]as[[:space:]]+/, "", a)
      sub(/[[:space:]].*$/, "", a)
      print a
      exit
    }' "$f")"
  if [[ -z $alias_name ]] || ! grep -qE "(^|[^A-Za-z0-9_.])${alias_name}\." "$f"; then
    CTL_ALIAS_UNUSED=$((CTL_ALIAS_UNUSED + 1))
    CTL_ALIAS_LIST+="$(rel_to_shell "$f"): ${alias_name:-<no alias>} is never read"$'\n'
  fi
done
t_eq "every QtQuick.Controls alias is used for a qualified read" "0" "$CTL_ALIAS_UNUSED"
if ((CTL_ALIAS_UNUSED > 0)); then
  t_note "unused aliases:"$'\n'"${CTL_ALIAS_LIST%$'\n'}"
fi

# --------------------------------------------------------------------------
t_section "cross-check only: qmllint's own import diagnostics"
# Not an assertion. A separate suite owns linting, and a suite that fails
# because a binary is absent is not a suite. Recorded so the numbers the
# README publishes can be read against this run.
if [[ -x $QMLLINT_BIN ]]; then
  lint_tmp="$(mktemp -d "${TMPDIR:-/tmp}/vb-imports-lint.XXXXXX")"
  ln -s "$SHELL_DIR" "$lint_tmp/qs"
  mapfile -t LINT_FILES < <(shell_qml_files)
  lint_out="$("$QMLLINT_BIN" -I "$lint_tmp" "${LINT_FILES[@]}" 2>&1 || true)"
  rm -rf "$lint_tmp"
  t_note "qmllint on ${#LINT_FILES[@]} files: $(grep -c 'Warning:' <<<"$lint_out") warnings, $(grep -c 'Error:' <<<"$lint_out") errors"
  t_note "of which unresolved-type/uncreatable-type: $(grep -cE 'unresolved-type|uncreatable-type' <<<"$lint_out")"
else
  t_note "qmllint is not at $QMLLINT_BIN, so the cross-check is unavailable and nothing is asserted about it"
fi

t_summary
