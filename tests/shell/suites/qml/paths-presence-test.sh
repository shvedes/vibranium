#!/bin/bash
# Suite: Paths and FilePresence - the two common/ singletons that resolve
# locations and answer "is this file there".
#
# The probe (suites/qml/probes/paths-presence.qml) imports the real `qs.common`
# singletons and prints one key per observation. This file turns those keys into
# assertions.
#
# Headless: QT_QPA_PLATFORM=offscreen, and the probe runs as an ordinary Item
# with no window, so nothing needs a compositor. qp_run kills the process as
# soon as the probe prints ##DONE##.
#
# The probe is launched TWICE. The first launch is the session as it is and runs
# the whole contract. The second launches the same probe with XDG_CONFIG_HOME
# and XDG_CACHE_HOME set to empty, which is the only way the StandardPaths
# fallback in Paths.qml:22-23 is ever executed: with the variables set that
# branch is dead code, and a source read cannot tell a working fallback from a
# broken one. The second launch asserts the fallback and everything the fallback
# feeds - separator hygiene, the derivations, the schema catalog - and skips the
# filesystem half, which would only re-observe the same temp directory.
#
# The filesystem half runs against a `mktemp -d` handed to the probe in
# VB_FP_TMP, so it is deterministic on any host and leaves nothing behind: the
# driver creates the fixtures, the probe removes the one file it creates itself,
# and the driver checks the temp dir's final listing plus the signature of every
# user and repo file Paths names.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "paths-presence" "resolved XDG/Vibranium paths, the schema catalog, and the refcounted presence tracker"
require_qs

PROBE="$TESTS_SHELL_DIR/suites/qml/probes/paths-presence.qml"

# The temp directory the probe works in, and the fixtures it reads. Three of the
# four exist before the run with a known content; absent.txt never exists, which
# is what makes the "present is false" cases real rather than accidental. peers.txt
# is the one file the probe may write to - it has to change content for the
# two-observer case to have a verdict change to follow.
FP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-fp.XXXXXX")"
export VB_FP_TMP="$FP_TMP"
FP_FIXTURES=(present.txt empty.txt peers.txt refcount.txt)
printf 'present content\n' >"$FP_TMP/present.txt"
: >"$FP_TMP/empty.txt"
printf 'peers content\n' >"$FP_TMP/peers.txt"
printf 'refcount content\n' >"$FP_TMP/refcount.txt"

# qp_setup assigns _QP_CFG inside a command substitution, so a caller's
# _QP_CFG stays empty and qp_run builds a second mirror for its second launch -
# and qp_teardown, which only knows about _QP_CFG, removes neither. Seeding the
# cache here makes the harness's own teardown work as written and keeps the
# launch count to one mirror.
_QP_CFG="$(qp_setup)"

# The harness mirror, the harness's probe output and this suite's fixtures are
# all torn down on exit. The fixtures hold the only file the probe creates, so
# they cannot outlive the run.
qp_cleanup() {
  qp_teardown
  if [[ -n ${_QP_OUT:-} && -f $_QP_OUT ]]; then
    rm -f "$_QP_OUT"
  fi
  if [[ -n ${FP_TMP:-} && -d $FP_TMP ]]; then
    rm -rf "$FP_TMP"
  fi
}

trap qp_cleanup EXIT

# The derived paths, in the order the probe walks them. Kept here as well as in
# the probe so a new derived property has to be added in both places to be
# covered; a name with no matching key fails loudly rather than going unnoticed.
DERIVED_PATHS=(
  configHome cacheHome themesUserRoot settingsFile settingsBundlePath
  settingsSchemaDir runtimeEnvFile themeNameFile
  themeStateDir themeBackgroundsDir themeColorsFile wallpaperStateJson
  screenshotsDir screenshotFallbackDir launcherUserPluginsDir drunCacheFile
  hyprInputFile hyprAppearanceFile hyprAdvancedFile hyprSmartGapsFile
  hyprAnimationsFile
)

# The raw env reads. A root is whatever the session says, so the
# no-trailing-separator rule does not apply to them; the doubled-separator rule
# does, because a root carrying one would double it in everything derived from
# it. The two XDG homes are kept apart: they are empty in the fallback launch by
# construction, so only the doubled-separator rule applies to them there.
ROOT_PATHS=(home vibraniumHome vibraniumCache vibraniumState vibraniumRuntime)
ROOT_PATHS_OPTIONAL=(xdgConfigHome xdgCacheHome)

# ---------------------------------------------------------------------------
# Small readers over the probe's output
# ---------------------------------------------------------------------------

# kv_list <key> - a probe value that is a newline-joined list. The probe escapes
# its newlines, so one KV stays one line; the escape is undone here.
kv_list() {
  sed 's/\\n/\n/g' <<<"$(qp_get "$1")"
}

# path_value <name> - one of the raw values the probe published under
# paths.values as alternating name/path lines, so the driver can stat and
# compare instead of guessing. Whole lines, so a path with a space survives.
path_value() {
  local name="$1" i pair
  local -a pairs=()
  while IFS= read -r pair; do
    pairs+=("$pair")
  done < <(kv_list paths.values)
  for ((i = 0; i + 1 < ${#pairs[@]}; i += 2)); do
    if [[ ${pairs[i]} == "$name" ]]; then
      printf '%s' "${pairs[i + 1]}"
      return 0
    fi
  done
  printf ''
}

# json_paths <key> - the paths out of a JSON array the probe printed.
json_paths() {
  grep -o '"[^"]*"' <<<"$(qp_get "$1")" | tr -d '"'
}

# signature <path> - what a file is, or MISSING. Type and size rather than
# mtime: the live shell rewrites the user's druncache and settings files on its
# own schedule, and a suite that fails because something else in the session was
# busy is a suite nobody trusts. A probe write shows up as a changed type or a
# changed size.
signature() {
  stat -c '%F|%s' -- "$1" 2>/dev/null || printf 'MISSING'
}

# tree_digest - a hash of the checkout's file list and sizes, .git excluded. This
# is what proves the probe wrote nothing into the repo, including into a schema
# file it only ever had a read-only FileView on.
tree_digest() {
  find "$VIBRANIUM_DIR" -path "$VIBRANIUM_DIR/.git" -prune -o -type f -printf '%p|%s\n' 2>/dev/null \
    | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

# dir_listing <dir> - the entries of a directory, one per line, sorted.
dir_listing() {
  find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort
}

repo_digest_before=""
audit_before=""

# ---------------------------------------------------------------------------
# Assertion groups
# ---------------------------------------------------------------------------

# Every derived path: containment under the root it came from, plus the literal
# suffix the derivation appends. Containment rather than equality to a fixed
# path, because every root is host-dependent; the suffix is what tells a right
# root from a wrong one.
assert_derivation() {
  local name
  for name in settingsFile themesUserRoot launcherUserPluginsDir hyprInputFile \
    hyprAppearanceFile hyprAdvancedFile hyprSmartGapsFile hyprAnimationsFile \
    settingsSchemaDir settingsBundlePath runtimeEnvFile themeNameFile themeStateDir \
    themeBackgroundsDir themeColorsFile wallpaperStateJson drunCacheFile \
    screenshotFallbackDir; do
    qp_assert "$name is under the root it was derived from" "derive.$name.under" "true"
  done
  qp_assert "settingsFile is configHome + /vibranium/settings.json" "derive.settingsFile.suffix" "true"
  qp_assert "themesUserRoot is configHome + /vibranium/themes" "derive.themesUserRoot.suffix" "true"
  qp_assert "settingsSchemaDir is vibraniumHome + /default/vibranium/settings" "derive.settingsSchemaDir.suffix" "true"
  qp_assert "settingsBundlePath is the catalog index under vibraniumHome" "derive.settingsBundlePath.suffix" "true"
  qp_assert "runtimeEnvFile is vibraniumRuntime + /settings.env" "derive.runtimeEnvFile.suffix" "true"
  qp_assert "themeNameFile is vibraniumState + /theme.name" "derive.themeNameFile.suffix" "true"
  qp_assert "themeBackgroundsDir is themeStateDir + /backgrounds" "derive.themeBackgroundsDir.suffix" "true"
  qp_assert "themeColorsFile is themeStateDir + /qs.json" "derive.themeColorsFile.suffix" "true"
  qp_assert "drunCacheFile is cacheHome + /vibranium/druncache.json" "derive.drunCacheFile.suffix" "true"
  qp_assert "screenshotFallbackDir is vibraniumCache + /screenshot-clipboard-fallbacks" \
    "derive.screenshotFallbackDir.suffix" "true"
  qp_assert "the five hyprland files share one config dir" "derive.hyprFiles.sharedDir" "true"
  qp_assert "settingsBundlePath sits under default/vibranium/settings" "derive.settingsBundlePath.underSettingsDir" "true"
  qp_assert "settingsBundlePath is the catalog's own index" "derive.settingsBundlePath.isTheIndex" "true"
  qp_assert "wallpaper.json is outside the theme payload" "derive.wallpaperStateJson.outsideTheme" "true"
  qp_assert "screenshotsDir is under the resolved pictures dir" "derive.screenshotsDir.under" "true"
  qp_assert "screenshotsDir ends in /Screenshots" "derive.screenshotsDir.suffix" "true"
  t_match "a pictures dir was resolved" '^/' "$(qp_get derive.screenshotsDir.picturesRoot)"
}

# The classic string-concatenation bug. A doubled separator is what an empty root
# or a root that already ends in one produces, and a trailing separator is what
# a root that already ends in one produces; both are invisible in a source read
# and obvious here.
assert_separator_hygiene() {
  local p
  for p in "${DERIVED_PATHS[@]}"; do
    qp_assert "$p has no doubled separator" "sep.$p.noDoubleSlash" "true"
    qp_assert "$p has no trailing separator" "sep.$p.noTrailingSlash" "true"
    qp_assert "$p is absolute" "sep.$p.absolute" "true"
  done
  for p in "${ROOT_PATHS[@]}"; do
    qp_assert "the $p root is non-empty" "root.$p.nonEmpty" "true"
    qp_assert "the $p root is absolute" "root.$p.absolute" "true"
    qp_assert "the $p root has no doubled separator" "sep.$p.noDoubleSlash" "true"
  done
  for p in "${ROOT_PATHS_OPTIONAL[@]}"; do
    qp_assert "the $p root has no doubled separator even when empty" "sep.$p.noDoubleSlash" "true"
  done
}

# The catalog is the one place in Paths where a name can go stale silently: a
# schema that was renamed leaves its options parsed by nothing, with no error
# anywhere. Shape here, existence on disk in the group below.
assert_catalog_shape() {
  local list
  for list in shell env hypr misc; do
    qp_assert "the $list catalog is not empty" "catalog.$list.nonEmpty" "true"
    qp_assert "every $list entry is under settingsSchemaDir" "catalog.$list.allUnderSchemaDir" "true"
    qp_assert "every $list entry is a .jsonc" "catalog.$list.allJsonc" "true"
    qp_assert "every $list entry is named" "catalog.$list.allNamed" "true"
    qp_assert "the $list catalog has no duplicate entry" "catalog.$list.noDuplicates" "true"
    qp_assert "no two $list entries share a basename" "catalog.$list.uniqueBasenames" "true"
    qp_assert "the $list catalog is in a stable order" "catalog.$list.sorted" "true"
  done
  qp_assert "the shell catalog names 13 schemas" "catalog.shell.count" "13"
  qp_assert "the env catalog names 2 schemas" "catalog.env.count" "2"
  qp_assert "the hypr catalog names 13 schemas" "catalog.hypr.count" "13"
  qp_assert "the misc catalog names 1 schema" "catalog.misc.count" "1"
  qp_assert "shell and env do not overlap each other" "catalog.cross.shellEnv.noDuplicates" "true"
  qp_assert "the misc catalog is a subset of the shell catalog" "catalog.misc.subsetOfShell" "true"
  qp_assert "the misc catalog adds nothing Settings has to dedupe away" "catalog.misc.contributesNoNewFiles" "true"
  qp_assert "the hypr catalog is disjoint from the Settings catalog" "catalog.hypr.disjointFromLoadable" "true"
  qp_assert "the loadable Settings catalog is 15 schemas" "catalog.total.loadable" "15"
  qp_assert "every catalog in the shell is 28 schemas" "catalog.total.withHypr" "28"
}

# The cross-file contract: every name the catalog holds has to be a file that is
# there, and every schema in the tree has to be a name some catalog holds. A
# catalog entry naming a schema that was renamed is a silent settings loss, and
# a schema no catalog names is an option the shell would never read - neither is
# visible to QML introspection.
assert_catalog_on_disk() {
  local schema_dir entry
  schema_dir="$(path_value settingsSchemaDir)"
  t_not_empty "the probe reported settingsSchemaDir" "$schema_dir"

  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    t_file "the catalog names a schema that exists: ${entry##*/}" "$entry"
  done < <( { json_paths catalog.shell.files; json_paths catalog.env.files; json_paths catalog.hypr.files; } )

  t_eq "the catalog names exactly the schemas in the tree" \
    "$(find "$schema_dir/shell" "$schema_dir/env" "$schema_dir/hypr" -type f -name '*.jsonc' | LC_ALL=C sort)" \
    "$( { json_paths catalog.shell.files; json_paths catalog.env.files; json_paths catalog.hypr.files; } | LC_ALL=C sort -u )"
  t_file "the schema directory has an index" "$schema_dir/_index.jsonc"
  t_eq "the index is the only schema outside the subdirectories" "_index.jsonc" \
    "$(find "$schema_dir" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)"
}

# The three functions. userThemesDir is the base the theme pickers compose from,
# userBackgroundsDir composes on top of it, and toFileUrl is the only way the
# shell hands a path to Image.source, so its encoding is a contract.
assert_functions() {
  qp_assert "userThemesDir is under themesUserRoot" "fn.userThemesDir.underRoot" "true"
  qp_assert "userThemesDir appends the theme name" "fn.userThemesDir.suffix" "true"
  qp_assert "userThemesDir is absolute" "fn.userThemesDir.absolute" "true"
  qp_assert "userThemesDir does not double a separator" "fn.userThemesDir.noDoubleSlash" "true"
  qp_assert "userBackgroundsDir appends /backgrounds to the theme dir" "fn.userBackgroundsDir.suffix" "true"
  qp_assert "userBackgroundsDir is under the theme dir" "fn.userBackgroundsDir.underUserThemes" "true"
  qp_assert "userBackgroundsDir is absolute" "fn.userBackgroundsDir.absolute" "true"
  qp_assert "toFileUrl percent-encodes a space and a hash" "fn.toFileUrl.encodes" "true"
  qp_assert "toFileUrl leaves no raw space" "fn.toFileUrl.noRawSpace" "true"
  qp_assert "toFileUrl percent-encodes non-ascii" "fn.toFileUrl.unicode" "true"
  qp_assert "toFileUrl of an empty path is bare" "fn.toFileUrl.empty" "true"
  qp_assert "toFileUrl of a null path is bare" "fn.toFileUrl.null" "true"
  qp_assert "toFileUrl of an undefined path is bare" "fn.toFileUrl.undefined" "true"
  qp_assert "toFileUrl drops an empty trailing segment" "fn.toFileUrl.dropsEmptySegments" "true"
  qp_assert "toFileUrl collapses a doubled separator" "fn.toFileUrl.dropsDoubledSeparator" "true"
  qp_assert "toFileUrl round-trips settingsFile" "fn.toFileUrl.roundTrips" "true"
  qp_assert "toFileUrl round-trips a path with a space" "fn.toFileUrl.roundTripsSpaces" "true"
  # An empty theme name is not rejected, it concatenates. Recorded rather than
  # asserted: nothing in the shell passes one, and the shape should be visible
  # from the suite if that ever changes.
  t_note "userThemesDir(\"\") returns a path with a trailing separator, because the argument is concatenated unchecked"
}

# The fallback branch of Paths.qml:22-23. Which side of the ternary ran, and
# whether what came back is a plain absolute path.
assert_fallback_shape() {
  qp_assert "the XDG config var is empty in the fallback launch" "paths.xdgConfigHome.isEmpty" "true"
  qp_assert "the XDG cache var is empty in the fallback launch" "paths.xdgCacheHome.isEmpty" "true"
  qp_assert "configHome came from StandardPaths, not the env" "paths.configHome.usedFallback" "true"
  qp_assert "cacheHome came from StandardPaths, not the env" "paths.cacheHome.usedFallback" "true"
  qp_assert "configHome did not come from the env" "paths.configHome.usedXdgEnv" "false"
  qp_assert "cacheHome did not come from the env" "paths.cacheHome.usedXdgEnv" "false"
  qp_assert "the config fallback is the platform XDG config home" "paths.configHome.fallbackIsXdgRoot" "true"
  qp_assert "the config fallback has no file:// scheme" "paths.configHome.noFileScheme" "true"
  qp_assert "the config fallback is absolute" "paths.configHome.isAbsolute" "true"
  qp_assert "the cache fallback has no file:// scheme" "paths.cacheHome.noFileScheme" "true"
  qp_assert "the cache fallback is absolute" "paths.cacheHome.isAbsolute" "true"
}

# FilePresence: the core.
assert_presence_core() {
  qp_assert "track() on an existing non-empty file reports present" "track.present.present" "true"
  qp_assert "track() returns an object" "track.present.isObject" "true"
  qp_assert "the handle carries the owner it was tracked with" "track.present.owner" "true"
  qp_assert "the handle carries the path it was tracked with" "track.present.path" "true"
  qp_assert "the handle's revision is a number" "track.present.revisionIsNumber" "true"
  qp_assert "a first present verdict bumps the revision" "track.present.revisionAtLeastOne" "true"
  qp_assert "track() on a missing file reports absent" "track.absent.present" "true"
  qp_assert "track() on a missing file returns an object" "track.absent.isObject" "true"
  qp_assert "an absent path never moves its revision" "track.absent.revisionIsZero" "true"
  qp_assert "an existing but zero-byte file is absent" "track.empty.present" "true"
  qp_assert "a zero-byte file is still tracked" "track.empty.isObject" "true"
  qp_assert "a zero-byte file never moves its revision" "track.empty.revisionIsZero" "true"
  qp_assert "a directory is tracked rather than refused" "track.directory.isObject" "true"
  qp_assert "a directory reads absent" "track.directory.present" "true"
  qp_assert "diagnostics() agrees a directory is absent" "track.directory.diag" "false"
}

assert_presence_refcount() {
  qp_assert "two owners get two handles" "refcount.handlesDistinct" "true"
  qp_assert "the two handles carry different owners" "refcount.ownersDistinct" "true"
  qp_assert "two observers of one path share one watcher and one prober" "refcount.oneWatcherForTwo" "true"
  qp_assert "the watcher count is 1" "refcount.diag.watchers" "1"
  qp_assert "the prober count is 1" "refcount.diag.probes" "1"
  qp_assert "the observer count is 2" "refcount.diag.observers" "2"
  qp_assert "both handles read present" "refcount.bothHandlesPresent" "true"
  qp_assert "releasing one observer succeeds" "refcount.release.first" "true"
  qp_assert "one observer is left" "refcount.afterOne.observers" "1"
  qp_assert "the watcher survives the first release" "refcount.afterOne.watchers" "1"
  qp_assert "the file is still reported present after one release" "refcount.afterOne.stillPresent" "true"
  qp_assert "the holder still reads present after one release" "refcount.afterOne.holderStillPresent" "true"
  qp_assert "the released handle keeps the verdict it was handed" "refcount.afterOne.releasedHandleVerdict" "true"
  qp_assert "releasing the last observer succeeds" "refcount.release.second" "true"
  qp_assert "the entry is gone once the last observer lets go" "refcount.afterTwo.entryGone" "true"
  qp_assert "releasing the same handle twice is refused" "refcount.doubleRelease" "false"
  qp_assert "releasing a non-handle is refused" "refcount.release.nonHandle" "false"
  qp_assert "releasing null is refused" "refcount.release.null" "false"
  qp_assert "releasing undefined is refused" "refcount.release.undefined" "false"
  qp_assert "five track/release cycles leave no residue" "refcount.cycle.allClean" "true"
  qp_assert "the observer count returns to where it started" "refcount.cycle.backToBase" "true"
  qp_assert "still one watcher after the cycles" "refcount.cycle.oneWatcherStill" "true"
}

assert_presence_reprobe() {
  qp_assert "the new path reads absent when tracked" "reprobe.trackedAbsent" "true"
  qp_assert "a newly tracked absent path is at revision 0" "reprobe.initialRevision" "0"
  qp_assert "the file can be created after being tracked" "reprobe.writeOk" "true"
  qp_assert "reprobe() reports the verdict moved when the file appears" "reprobe.create.returned" "true"
  qp_assert "reprobe() flips the path to present" "reprobe.create.present" "true"
  qp_assert "the flip moves the handle's revision" "reprobe.create.revisionAdvanced" "true"
  qp_assert "reprobe() on an unchanged verdict reports no move" "reprobe.create.idempotent" "false"
  qp_assert "the path is still present" "reprobe.create.stillPresent" "true"
  qp_assert "diagnostics() agrees the path is present" "reprobe.create.diagPresent" "true"
  qp_assert "reprobe() reports the verdict moved when the file is deleted" "reprobe.delete.present" "true"
  qp_assert "the deletion moves the handle's revision" "reprobe.delete.revisionAdvanced" "true"
  qp_assert "diagnostics() agrees the path is absent" "reprobe.delete.diagPresent" "false"
  qp_assert "reprobe() is settled after the deletion" "reprobe.delete.settled" "false"
  qp_assert "the path is still absent" "reprobe.delete.stillAbsent" "true"
  qp_assert "reprobe() on an untracked path is refused" "reprobe.unknownPath" "false"
  qp_assert "reprobe() on an empty path is refused" "reprobe.emptyPath" "false"
  qp_assert "reprobe() on a null path is refused" "reprobe.nullPath" "false"
  qp_assert "reprobe() on a non-string path is refused" "reprobe.numberPath" "false"
  qp_assert "reprobe() on an undefined path is refused" "reprobe.undefinedPath" "false"
}

# refresh() answers the verdict a read produced; reprobe() answers whether the
# verdict moved. Each has to do what its name says, and each has to answer on a
# handle that is no longer live.
assert_presence_refresh() {
  qp_assert "refresh() of a present file answers true" "refresh.present" "true"
  qp_assert "refresh() leaves the handle present" "refresh.present.stillPresent" "true"
  qp_assert "refresh() of an absent file answers false" "refresh.absent" "false"
  qp_assert "refresh() leaves the handle absent" "refresh.absent.stillAbsent" "true"
  qp_assert "refresh(null) answers false" "refresh.null" "false"
  qp_assert "refresh(undefined) answers false" "refresh.undefined" "false"
  qp_assert "two observers of one path start on the same verdict" "refresh.peers.startEqual" "true"
  qp_assert "the shared path starts present" "refresh.peers.startPresent" "true"
  qp_assert "the two observers share one watcher" "refresh.peers.diagWatchers" "1"
  qp_assert "the observer count is 2" "refresh.peers.diagObservers" "2"
  qp_assert "refresh() of one observer answers true after a fill" "refresh.peerA.afterFill" "true"
  qp_assert "every observer of the path follows the same verdict" "refresh.peers.agreeAfter" "true"
  qp_assert "every observer of the path follows the same revision" "refresh.peers.revisionsAgree" "true"
  qp_assert "releasing both observers succeeds" "refresh.peers.releasedBoth" "true"
  qp_assert "the entry is gone once both let go" "refresh.peers.entryGone" "true"
  qp_assert "refresh() of an absent handle answers false" "refresh.stale.beforeRelease" "false"
  qp_assert "the stale handle is released" "refresh.stale.release" "true"
  qp_assert "refresh() of a released handle answers false" "refresh.stale.afterRelease" "false"
  qp_assert "a released handle does not resurrect its entry" "refresh.stale.entryGone" "true"
}

# diagnostics() is read field by field, so the key set is the contract.
assert_presence_diagnostics() {
  qp_assert "four paths are tracked at this point" "diag.trackedPaths" "4"
  qp_assert "the diagnostics key set is stable" "diag.keySet" "observers,present,probes,revision,watchers"
  qp_assert "every documented field is present" "diag.entryFields" "true"
  qp_assert "diagnostics() returns an object" "diag.isObject" "true"
  qp_assert "diagnostics() is stable across calls" "diag.isStableAcrossCalls" "true"
  qp_assert "the diagnostics fields have the documented types" "diag.valueTypes" "true"
  qp_assert "the observer count is the live handle count" "diag.observersMatch" "true"
  qp_assert "_entries starts empty" "fp.entries.startsEmpty" "true"
  qp_assert "_entries is an object" "fp.entries.isObject" "true"
  qp_assert "rev is a number" "fp.rev.isNumber" "true"
  qp_assert "rev starts at 0" "fp.rev.start" "0"
  qp_assert "diagnostics is callable" "fp.diag.isFunction" "true"
}

# The pure rule, exercised with no filesystem at all.
assert_presence_verdict() {
  qp_assert "a completed non-empty read is present" "verdict.okTrue.nonEmpty" "true"
  qp_assert "surrounding whitespace does not empty a read" "verdict.okTrue.padded" "true"
  qp_assert "non-ascii content is present" "verdict.okTrue.utf8" "true"
  qp_assert "a completed empty read is absent" "verdict.okTrue.empty" "true"
  qp_assert "a completed whitespace-only read is absent" "verdict.okTrue.whitespace" "true"
  qp_assert "a newline-only read is absent" "verdict.okTrue.newlineOnly" "true"
  qp_assert "an incomplete read is absent even with content" "verdict.okFalse.nonEmpty" "true"
  qp_assert "an incomplete empty read is absent" "verdict.okFalse.empty" "true"
  qp_assert "ok=1 is not the boolean true" "verdict.ok.isOne" "true"
  qp_assert "ok=\"true\" is not the boolean true" "verdict.ok.isStringTrue" "true"
  qp_assert "ok=null is not the boolean true" "verdict.ok.isNull" "true"
  qp_assert "ok=undefined is not the boolean true" "verdict.ok.isUndefined" "true"
  qp_assert "an object ok is not the boolean true" "verdict.ok.isObject" "true"
  qp_assert "verdict() with no arguments is absent" "verdict.ok.missing" "true"
  qp_assert "a null text is not text" "verdict.text.isNull" "true"
  qp_assert "an undefined text is not text" "verdict.text.isUndefined" "true"
  qp_assert "a numeric text is not text" "verdict.text.isNumber" "true"
  qp_assert "an array text is not text" "verdict.text.isArray" "true"
  qp_assert "an object text is not text" "verdict.text.isObject" "true"
  qp_assert "verdict() returns a boolean when present" "verdict.returnsBool.true" "true"
  qp_assert "verdict() returns a boolean when absent" "verdict.returnsBool.false" "true"
}

# Every argument shape the contract names. A throw would land in probe.error,
# which the driver requires to be absent, so "none of them throw" is enforced by
# the whole run as much as by these keys.
assert_presence_validation() {
  qp_assert "a blank owner is refused" "validate.blankOwner" "null"
  qp_assert "a null owner is refused" "validate.nullOwner" "null"
  qp_assert "a numeric owner is refused" "validate.numberOwner" "null"
  qp_assert "an object owner is refused" "validate.objectOwner" "null"
  qp_assert "a null path is refused" "validate.nullPath" "null"
  qp_assert "an empty path is refused" "validate.emptyPath" "null"
  qp_assert "a numeric path is refused" "validate.numberPath" "null"
  qp_assert "an undefined path is refused" "validate.undefinedPath" "null"
  qp_assert "track() with no arguments is refused" "validate.noArgs" "null"
  qp_assert "a refused track registers no observation" "validate.rejectsLeftNoObservation" "true"
  qp_assert "a path with a space is tracked" "validate.spacedPath.tracked" "true"
  qp_assert "a path with a space reads absent when missing" "validate.spacedPath.present" "true"
  qp_assert "a path with a space is releasable" "validate.spacedPath.released" "true"
  qp_assert "a released path with a space leaves no entry" "validate.spacedPath.entryGone" "true"
  qp_assert "a 200-character basename is tracked" "validate.longPath.tracked" "true"
  qp_assert "a 200-character basename reads absent when missing" "validate.longPath.present" "true"
  qp_assert "a long path is releasable" "validate.longPath.released" "true"
  qp_assert "a released long path leaves no entry" "validate.longPath.entryGone" "true"
}

assert_presence_cleanup() {
  qp_assert "the file the probe created is gone" "cleanup.lateFileRemoved" "true"
  qp_assert "the verification handle is released" "cleanup.lateHandleReleased" "true"
  qp_assert "every handle the probe took is released" "cleanup.everyHandleReleased" "true"
  qp_assert "no path is left tracked" "cleanup.noTrackedPaths" "0"
  qp_assert "_entries is empty again" "cleanup.entriesEmpty" "0"
  qp_assert "the aggregate revision moved" "cleanup.revAdvanced" "true"
}

# Every path the probe opened, watched or wrote has to be under the directory the
# driver handed over. This is the machine-checked form of "the probe wrote
# nothing outside its temp dir".
assert_probe_stayed_in_tempdir() {
  local path used=0 outside=0
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    used=$((used + 1))
    if [[ $path != "$FP_TMP" && $path != "$FP_TMP"/* ]]; then
      t_no "the probe only touched its temp dir: ${path##*/}" \
        "$(printf 'outside %s: %s' "$FP_TMP" "$path")"
      outside=$((outside + 1))
    fi
  done < <(kv_list fp.pathsUsed)
  t_count "every path the probe used was inside the temp dir" "$used" "$((used - outside))"
}

# The filesystem the probe was given, seen from bash: the fixtures are as the
# driver left them, the file the probe created is gone, and the directory holds
# nothing else - no atomic-write leftover, no stray entry.
assert_tempdir_after() {
  local label="$1"
  t_file "$label: present.txt survives" "$FP_TMP/present.txt"
  t_file "$label: empty.txt survives" "$FP_TMP/empty.txt"
  t_file "$label: peers.txt survives" "$FP_TMP/peers.txt"
  t_file "$label: refcount.txt survives" "$FP_TMP/refcount.txt"
  t_eq "$label: present.txt is byte-for-byte what the driver wrote" \
    "$(printf 'present content\n' | sha256sum)" \
    "$(sha256sum <"$FP_TMP/present.txt")"
  t_eq "$label: refcount.txt is byte-for-byte what the driver wrote" \
    "$(printf 'refcount content\n' | sha256sum)" \
    "$(sha256sum <"$FP_TMP/refcount.txt")"
  t_eq "$label: empty.txt is still zero bytes" "0" "$(stat -c '%s' -- "$FP_TMP/empty.txt")"
  t_no_file "$label: the probe's own file is gone" "$FP_TMP/late.txt"
  t_no_file "$label: the absent fixture was never created" "$FP_TMP/absent.txt"
  t_no_file "$label: the stale fixture was never created" "$FP_TMP/stale.txt"
  t_no_file "$label: the spaced fixture was never created" "$FP_TMP/a b.txt"
  t_eq "$label: the temp dir holds only the driver's fixtures" \
    "$(printf '%s\n' "${FP_FIXTURES[@]}" | LC_ALL=C sort)" \
    "$(dir_listing "$FP_TMP")"
}

# Fingerprint every file Paths names on this host, before the launch. The count
# is exact and therefore load-bearing: 12 derived entries, plus
# 12 + 3 + 13 + 1 catalog entries, of which miscCatalogFiles[0] is
# shellCatalogFiles[0] by design - 40 distinct files.
assert_paths_files_fingerprint() {
  local label="$1" path
  audit_before=""
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    audit_before+="$path"$'\t'"$(signature "$path")"$'\n'
  done < <(kv_list paths.auditFiles | LC_ALL=C sort -u)
  t_count "$label: every derived and catalogued file was fingerprinted" "40" \
    "$(printf '%s' "$audit_before" | grep -c .)"
}

assert_paths_files_untouched() {
  local label="$1" path before after changed=0 total=0
  while IFS=$'\t' read -r path before; do
    [[ -n $path ]] || continue
    total=$((total + 1))
    after="$(signature "$path")"
    if [[ $before != "$after" ]]; then
      t_no "$label: unchanged: $(rel_to_shell "$path")" \
        "$(printf 'before: %s\nafter:  %s' "$before" "$after")"
      changed=$((changed + 1))
    fi
  done < <(printf '%s' "$audit_before")
  t_count "$label: no derived or catalogued file was written" "$total" "$((total - changed))"
  t_eq "$label: the checkout is byte-identical" "$repo_digest_before" "$(tree_digest)"
}

# ---------------------------------------------------------------------------
# Launch 1: the session as it is. The whole contract.
# ---------------------------------------------------------------------------
repo_digest_before="$(tree_digest)"

t_section "the probe ran, and every step finished"
if ! qp_run "$PROBE" 40; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi
t_not_empty "the probe produced observations" "$(qp_get paths.exists)"
t_eq "the probe ran in session mode" "env" "$(qp_get probe.mode)"
t_eq "the probe ran every step it planned" "$(qp_get probe.steps.planned)" "$(qp_get probe.steps.ran)"
t_eq "no probe step threw" "absent" "$(qp_probe_ran probe.error && printf present || printf absent)"

t_section "both singletons are reachable"
qp_assert "Paths is a singleton object" "paths.exists" "object"
qp_assert "FilePresence is a singleton object" "fp.exists" "object"

t_section "the roots the shell depends on are the session's own"
qp_assert "home is non-empty" "root.home.nonEmpty" "true"
qp_assert "home is absolute" "root.home.absolute" "true"
qp_assert "home is \$HOME" "root.home.matchesEnv" "true"
qp_assert "vibraniumHome is non-empty" "root.vibraniumHome.nonEmpty" "true"
qp_assert "vibraniumHome is absolute" "root.vibraniumHome.absolute" "true"
qp_assert "vibraniumHome is \$VIBRANIUM" "root.vibraniumHome.matchesEnv" "true"
qp_assert "vibraniumState is non-empty" "root.vibraniumState.nonEmpty" "true"
qp_assert "vibraniumState is \$VIBRANIUM_STATE" "root.vibraniumState.matchesEnv" "true"
qp_assert "vibraniumCache is non-empty" "root.vibraniumCache.nonEmpty" "true"
qp_assert "vibraniumCache is \$VIBRANIUM_CACHE" "root.vibraniumCache.matchesEnv" "true"
qp_assert "vibraniumRuntime is non-empty" "root.vibraniumRuntime.nonEmpty" "true"
qp_assert "vibraniumRuntime is \$VIBRANIUM_RUNTIME" "root.vibraniumRuntime.matchesEnv" "true"

t_section "an explicit XDG home wins over the platform default"
qp_assert "XDG_CONFIG_HOME is set" "paths.xdgConfigHome.isEmpty" "false"
qp_assert "XDG_CACHE_HOME is set" "paths.xdgCacheHome.isEmpty" "false"
qp_assert "configHome is XDG_CONFIG_HOME" "paths.configHome.usedXdgEnv" "true"
qp_assert "cacheHome is XDG_CACHE_HOME" "paths.cacheHome.usedXdgEnv" "true"
qp_assert "configHome did not take the fallback" "paths.configHome.usedFallback" "false"
qp_assert "cacheHome did not take the fallback" "paths.cacheHome.usedFallback" "false"
qp_assert "configHome carries no file:// scheme" "paths.configHome.noFileScheme" "true"
qp_assert "cacheHome carries no file:// scheme" "paths.cacheHome.noFileScheme" "true"
qp_assert "configHome is absolute" "paths.configHome.isAbsolute" "true"
qp_assert "cacheHome is absolute" "paths.cacheHome.isAbsolute" "true"

t_section "every derived path is consistent with the root it came from"
assert_derivation

t_section "no derived path has a doubled or a trailing separator"
assert_separator_hygiene

t_section "the schema catalog is well formed"
assert_catalog_shape

t_section "every name the catalog holds is a file that is there"
assert_catalog_on_disk

t_section "the three Paths functions"
assert_functions

t_section "FilePresence is located by a stable tag"
qp_assert "the tag is exactly the documented string" "fp.tag" "filePresence"
qp_assert "the tag is a string" "fp.tag.isString" "true"
qp_assert "the tag is non-empty" "fp.tag.nonEmpty" "true"
qp_assert "the tag is lowerCamelCase like every other tagged singleton" "fp.tag.camelCase" "true"
qp_assert "the tag carries no path character" "fp.tag.noPathChars" "true"

t_section "verdict(ok, text) is the whole tri-state, with no filesystem"
assert_presence_verdict

t_section "track() answers for a file that is there and one that is not"
assert_presence_core

t_section "the count follows the path, not the consumer"
assert_presence_refcount

t_section "reprobe() follows a file appearing and disappearing"
assert_presence_reprobe

t_section "refresh() answers the read; a stale handle answers false"
assert_presence_refresh

t_section "diagnostics() exposes a stable key set"
assert_presence_diagnostics

t_section "track() refuses bad arguments without throwing"
assert_presence_validation

t_section "the probe left nothing tracked and nothing outside its temp dir"
assert_presence_cleanup
assert_probe_stayed_in_tempdir
assert_tempdir_after "session"

t_section "nothing outside the temp dir was written"
assert_paths_files_fingerprint "session"
assert_paths_files_untouched "session"

# ---------------------------------------------------------------------------
# Launch 2: the same probe with both XDG home variables empty, which is the only
# way the StandardPaths fallback in Paths.qml:22-23 ever runs. The fallback's
# blast radius is configHome and cacheHome and everything derived from them, so
# this launch re-checks the derivations, the separator hygiene and the catalog
# rather than the filesystem half, which would only re-observe the same temp dir.
# ---------------------------------------------------------------------------
export XDG_CONFIG_HOME=""
export XDG_CACHE_HOME=""

t_section "the probe runs again with the XDG homes empty"
if ! qp_run "$PROBE" 40; then
  t_no "the fallback probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi
t_eq "the fallback launch took the fallback branch" "fallback" "$(qp_get probe.mode)"
t_eq "the fallback launch ran every step it planned" "$(qp_get probe.steps.planned)" "$(qp_get probe.steps.ran)"
t_eq "no fallback probe step threw" "absent" "$(qp_probe_ran probe.error && printf present || printf absent)"
t_eq "the fallback launch skipped the filesystem half" "fallback launch" "$(qp_get fp.summary.skipped)"

t_section "the StandardPaths fallback still produces plain absolute paths"
assert_fallback_shape
assert_separator_hygiene

t_section "the fallback leaves every derivation consistent"
assert_derivation

t_section "the fallback leaves the schema catalog intact"
assert_catalog_shape
assert_catalog_on_disk

t_section "the fallback launch still wrote nothing"
assert_paths_files_fingerprint "fallback"
assert_paths_files_untouched "fallback"
assert_tempdir_after "fallback"

# The documented contradiction, recorded rather than asserted. Paths.qml:23
# falls back to StandardPaths.CacheLocation, which is APPLICATION-scoped, so with
# XDG_CACHE_HOME empty the shell resolves its cache home to $HOME/.cache/<appname>
# rather than the $XDG_CACHE_HOME that Paths.qml:110 documents the drun cache
# lives in. The resolved value is pinned so a change to it is visible, and the
# mismatch is noted; asserting the documented value would be asserting something
# the code does not do.
t_section "the cache fallback is not the XDG cache home"
t_note "Paths.qml:23 falls back to StandardPaths.CacheLocation, which is application-scoped: with XDG_CACHE_HOME empty, cacheHome resolved to $(qp_get paths.cacheHome.fallbackValue), not the \$XDG_CACHE_HOME that Paths.qml:110 documents for the drun cache"
t_eq "the cache fallback is the value the code actually produced" \
  "$(path_value cacheHome)" "$(qp_get paths.cacheHome.fallbackValue)"
t_eq "the observed fallback is not the XDG cache root" "false" \
  "$(qp_get paths.cacheHome.fallbackIsXdgRoot)"

t_summary
