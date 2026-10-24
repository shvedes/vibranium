#!/bin/bash
# Suite: construction - every type the tree's qmldir files declare, built.
#
# The probe (suites/qml/probes/construction.qml) reads a case list this file
# generates and builds each case, printing one `type.<module>.<Name>=<bucket>`
# per declared entry. This file owns the list, the buckets and the assertions.
#
# The claim under test is narrow on purpose: a declared type must construct
# under the offscreen platform without a QML error. Not "renders correctly" -
# QT_QPA_PLATFORM=offscreen drives no render loop, so there is nothing to
# render into. What construction does catch is the class of defect that
# actually happens: a qmldir entry pointing at a file that no longer declares
# the type, a binding that throws while the object is built, a circular
# component dependency, a JS type error in a Component.onCompleted.
#
# Four buckets, exactly one per declared entry:
#
#   clean                    built, no error.
#   declared-but-uncreatable the entry's own root object is a type Quickshell
#                            registers from C++ - 15 PanelWindow, 6 Variants,
#                            1 WlSessionLockSurface. PanelWindow is one of the
#                            names qmllint reports as `uncreatable-type`, for
#                            the same reason this suite will not build it; the
#                            other two are never used in a position qmllint
#                            flags, so the check is against the installed type
#                            descriptions rather than against qmllint's output.
#   needs-environment        built only with a real windowing backend, screen,
#                            audio daemon, polkit agent or Quickshell.screens
#                            entry. The reason string is the type's own, not a
#                            guess, and the list is pinned.
#   broken                   a genuine construction error. MUST BE EMPTY.
#
# A `required property` is not any of those: "Required property flickable was
# not initialized" is correct code refusing an incomplete construction, so the
# probe supplies whatever the engine names and asks again.
#
# The suites around this one check the same tree from the outside - the static
# suite lints it, the architecture suite parses every qmldir, and
# suites/qml/unitgate-test.sh drives the one singleton with a real state
# machine. None of them ever asked the engine to build anything.
#
# Headless: QT_QPA_PLATFORM=offscreen, the probe is an ordinary Item with no
# window, and each case is compiled and built as its own one-object document, so
# one type that cannot be built neither ends the run nor hides the other 227.
# qp_run kills the process group on the ##DONE## sentinel.

# Whether the runner owns the result file. Captured before harness.sh is
# sourced, because a standalone run gets a private one from it and the runner's
# copy must never be touched.
RUNNER_RESULTS="${SHELL_TEST_RESULTS:-}"

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "construction" "every qmldir-declared type builds headlessly, and the ones that cannot say why"
require_qs

require_tools awk find sort grep sed mktemp wc cut tr

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-construction.XXXXXX")"

# A private view of the filesystem for the probe, exported before qp_run starts
# anything. Building a declared type is the widest thing this suite does: it
# constructs the shell's own Paths, Settings, FilePresence and Watch singletons,
# which read the session's XDG roots and the VIBRANIUM_* paths derived from
# them. Nothing here needs the user's real configuration - the verdicts are
# identical against an empty one - so the probe is given an empty one instead.
# That is insurance in both directions: the run cannot write to the user's
# settings, and a broken settings file on this host cannot change a verdict.
#
# qp_run runs qs through `env`, which passes the inherited environment through,
# so exporting here is what the probe process sees.
ISOLATION="$WORK/env"
mkdir -p "$ISOLATION/config" "$ISOLATION/state" "$ISOLATION/cache" \
  "$ISOLATION/data" "$ISOLATION/run"
export XDG_CONFIG_HOME="$ISOLATION/config"
export XDG_STATE_HOME="$ISOLATION/state"
export XDG_CACHE_HOME="$ISOLATION/cache"
export XDG_DATA_HOME="$ISOLATION/data"
export VIBRANIUM_RUNTIME="$ISOLATION/run"

# The harness's mirror of the shell tree, seeded here because qp_setup assigns
# _QP_CFG inside a command substitution: a caller that never learns the path
# gets a second mirror per run and qp_teardown removes neither. The generated
# case list has to be written into the mirror the probe runs in, so the probe
# and the list have to share one.
_QP_CFG="$(qp_setup)"

# The harness's own teardown knows about the mirror and its probe output; this
# suite adds the work tables, which are derived data and must not outlive the
# run. It also takes over the EXIT trap, which is what harness.sh used to remove
# a standalone run's private result file, so that removal moves here with it.
cleanup() {
  qp_teardown
  if [[ -n ${WORK:-} && -d $WORK ]]; then
    rm -rf "$WORK"
  fi
  if [[ -z $RUNNER_RESULTS && -n ${SHELL_TEST_RESULTS:-} ]]; then
    rm -f "$SHELL_TEST_RESULTS"
  fi
}

trap cleanup EXIT

# --------------------------------------------------------------------------
# the work list
# --------------------------------------------------------------------------
#
# The same awk the architecture suite uses, so the two agree on what a qmldir
# entry is: `Type Version File` or `singleton Type Version File`, nothing else.
# ENTRIES rows: module, name, kind, relative file, directory, line.
QMLDIRS="$WORK/qmldirs"
ENTRIES="$WORK/entries.tsv"

shell_qmldir_files >"$QMLDIRS"
[[ -s $QMLDIRS ]] || t_block "no qmldir file was found under $SHELL_DIR"

mapfile -t QMLDIR_LIST <"$QMLDIRS"

awk -v ent="$ENTRIES" '
  BEGIN { OFS = "\t" }
  FNR == 1 { dir = FILENAME; sub(/\/qmldir$/, "", dir); module = "" }
  /^module[[:space:]]/ {
    module = $2
    next
  }
  NF {
    if ($1 == "singleton") { kind = "singleton"; name = $2; ver = $3; rel = $4 }
    else                    { kind = "type";      name = $1; ver = $2; rel = $3 }
    print module, name, kind, rel, dir, FNR > ent
  }
' "${QMLDIR_LIST[@]}"

QMLDIR_COUNT="$(wc -l <"$QMLDIRS" | tr -d ' ')"
ENTRY_COUNT="$(wc -l <"$ENTRIES" | tr -d ' ')"
[[ $ENTRY_COUNT -gt 0 ]] || t_block "no qmldir entry was parsed out of $QMLDIR_COUNT qmldir files"

# The root object each entry's file declares. A QML type is declared by the
# file that holds it: the root object, which the language requires to sit at
# column 0. This is the same detection the architecture suite uses to check
# that every entry's file provides the type.
ROOTS="$WORK/roots.tsv"
: >"$ROOTS"
while IFS=$'\t' read -r e_mod e_name e_kind e_rel e_dir _e_line; do
  root="$(awk '/^[A-Za-z_][A-Za-z0-9_]*[ \t]*\{/ { print $1; exit }' "$e_dir/$e_rel")"
  printf '%s\t%s\t%s\t%s\n' "$e_mod" "$e_name" "$root" "$e_rel" >>"$ROOTS"
done <"$ENTRIES"

# The Quickshell C++-registered types, read out of the installed type
# descriptions rather than from a list in this file. The static suite
# cross-checks its unresolved-type set the same way, and the reason is the same:
# "this is a Quickshell type registered from C++" is a checked fact, not an
# accepted excuse. A name that is in no quickshell-*.qmltypes is some other
# type that lost its import, and it belongs in `broken`.
QS_QMLTYPES="$(dirname "$(dirname "$QMLLINT_BIN")")/qml/Quickshell"
[[ -d $QS_QMLTYPES ]] || t_block "no quickshell type descriptions at $QS_QMLTYPES, so C++-registered roots cannot be told from shell types"

CXX_TYPES="$WORK/quickshell-types.txt"
grep -rh 'exports: \[' "$QS_QMLTYPES" --include='*.qmltypes' \
  | awk -F'"' '{ split($2, v, " "); n = split(v[1], a, "/"); if (n == 2) print a[2] }' \
  | LC_ALL=C sort -u >"$CXX_TYPES"
[[ -s $CXX_TYPES ]] || t_block "no exported type could be read out of $QS_QMLTYPES/*.qmltypes"

# is_cxx_root answers whether a root object is a type Quickshell registers from
# C++. `Singleton` is excluded on purpose: every `pragma Singleton` file's root
# object is the QML base type of that name, and Quickshell also exports a C++
# type called Singleton - without the guard all 87 singletons would be written
# off as uncreatable instead of being built through their name.
is_cxx_root() {
  [[ -n $1 && $1 != Singleton ]] && grep -qx -- "$1" "$CXX_TYPES"
}

# The one entry this suite must never build. boot/Boot.qml is the composition
# root: its Component.onCompleted drains the whole boot catalog, so
# constructing it starts the shell - a second one, in a test run. It is
# excluded here rather than classified, because "works" is not a question that
# can be asked about it in a test process.
# The pair a boot-safety exclusion is written as, spelled with a variable
# rather than a literal tab so the file holds no tab characters at all.
KEY_TAB=$'\t'
BOOT_EXCLUDED="qs.boot${KEY_TAB}Boot"

# The recorded sets. Both are exact lists rather than counts, because a count
# says how much moved and a list says what moved, and what moved is the whole
# question here: a type that starts needing a new environment has to be
# visible, not absorbed into a number that still adds up.
#
# EXPECTED_UNCREATABLE is derived rather than typed - the driver computes it
# from the installed quickshell-*.qmltypes and the root object of each entry's
# file - so the pin is what stops a new C++ root from quietly widening the set.
#
# EXPECTED_NEEDS_ENVIRONMENT is 95 of the 230 declared types, and every one of them
# through the same door. Under QT_QPA_PLATFORM=offscreen Quickshell loads no
# PanelWindow backend, so any type that reaches a window - directly as a
# PanelWindow root, or through a singleton that builds one while it is being
# constructed - cannot be built at all. That is one environmental
# fact with a long reach, not 94 separate problems, and the reason string each
# type carries says so.
EXPECTED_UNCREATABLE="qs.common.IslandHost
qs.common.ScrimWindow
qs.features.annotations.AnnotationEditor
qs.features.annotations.AnnotationOverlay
qs.features.annotations.CapturePicker
qs.features.bar.BarShadow
qs.features.bar.BarView
qs.features.bar.MoveWindow
qs.features.bar.PrivacyOverlay
qs.features.bar.ToolTipHost
qs.features.bar.modules.ColorPicker.ColorPickerOverlay
qs.features.bar.modules.Tray.TrayMenu
qs.features.clipboard.ClipboardView
qs.features.launcher.AppLauncherView
qs.features.lock.LockscreenSurfaceView
qs.features.menu.MenuView
qs.features.notifications.NotificationsView
qs.features.osd.OSDView
qs.features.polkit.PolkitView
qs.features.powerMenu.PowerMenuView
qs.features.wallpaper.WallpaperView
qs.features.wallpaperPicker.WallpaperPickerView"

EXPECTED_NEEDS_ENVIRONMENT="qs.boot.BootLate
qs.common.OverlayWindow
qs.features.annotations.AnnotationController
qs.features.apps.audioMixer.AudioMixer
qs.features.apps.audioMixer.AudioMixerController
qs.features.apps.audioMixer.AudioMixerWindow
qs.features.apps.audioMixer.DeviceRow
qs.features.apps.audioMixer.GraphNode
qs.features.apps.audioMixer.GraphTab
qs.features.apps.audioMixer.StreamRow
qs.features.apps.audioMixer.VolumeSlider
qs.features.bar.Bar
qs.features.bar.BarModule
qs.features.bar.CollapsibleSlot
qs.features.bar.Group
qs.features.bar.ToolTipBind
qs.features.bar.Zone
qs.features.bar.modules.ArchUpdates.ArchUpdates
qs.features.bar.modules.ColorPicker.ColorPicker
qs.features.bar.modules.KeyboardLayout.KeyboardLayout
qs.features.bar.modules.Logout.Logout
qs.features.bar.modules.Network.Network
qs.features.bar.modules.Network.NetworkIsland
qs.features.bar.modules.Network.NetworkQrOverlay
qs.features.bar.modules.NowPlaying.NowPlaying
qs.features.bar.modules.NowPlaying.NowPlayingIsland
qs.features.bar.modules.PowerProfile.PowerProfile
qs.features.bar.modules.Printers.Printers
qs.features.bar.modules.Printers.PrintersIsland
qs.features.bar.modules.Privacy.Privacy
qs.features.bar.modules.Tray.Tray
qs.features.bar.modules.Volume.Volume
qs.features.bar.modules.Volume.VolumeIsland
qs.features.bar.modules.Weather.Weather
qs.features.bar.modules.Weather.WeatherIsland
qs.features.clipboard.Clipboard
qs.features.clipboard.ClipboardEntry
qs.features.clipboard.ClipboardPanel
qs.features.clipboard.ClipboardPreview
qs.features.launcher.AppLauncher
qs.features.launcher.AppLauncherController
qs.features.launcher.LauncherEntry
qs.features.launcher.LauncherPanel
qs.features.launcher.PluginInstance
qs.features.lock.Lockscreen
qs.features.lock.NowPlaying
qs.features.menu.Entry
qs.features.menu.GridCell
qs.features.menu.InlineEditor
qs.features.menu.Menu
qs.features.menu.MenuPanel
qs.features.menu.NumberPicker
qs.features.menu.OptionRow
qs.features.notifications.NotificationCard
qs.features.notifications.NotificationEntry
qs.features.notifications.Notifications
qs.features.osd.OSD
qs.features.osd.OSDCard
qs.features.pass.Pass
qs.features.pass.PassController
qs.features.pass.PassEntry
qs.features.pass.PassPanel
qs.features.pickers.cursor.CursorPicker
qs.features.pickers.font.FontPicker
qs.features.pickers.keybindings.Keybindings
qs.features.pickers.theme.ThemePicker
qs.features.pickers.theme.ThemeRemover
qs.features.polkit.Polkit
qs.features.powerMenu.PowerMenu
qs.features.powerMenu.PowerMenuPanel
qs.features.wallpaper.Wallpaper
qs.features.wallpaperPicker.WallpaperEntry
qs.features.wallpaperPicker.WallpaperPicker
qs.features.wallpaperPicker.WallpaperPickerPanel
qs.services.ArchUpdates
qs.services.Audio
qs.services.BatteryAlert
qs.services.Connectivity
qs.services.IdleDaemon
qs.services.Inhibitor
qs.services.Keyboard
qs.services.MediaArt
qs.services.MediaEvents
qs.services.MediaState
qs.services.PipeWireState
qs.services.PowerPolicy
qs.services.PowerProfile
qs.services.Printers
qs.services.Privacy
qs.services.Recording
qs.services.Screenshots
qs.services.Session
qs.services.Timer
qs.services.Update
qs.services.Weather"

# The distinct reasons a type gave. Each is the phrase Quickshell put in its own
# diagnostic, so this is the whole environmental vocabulary the tree currently
# needs; a new one is a change to decide rather than a change to absorb.
EXPECTED_NEEDS_REASONS="No PanelWindow backend loaded"

# A `required property` is correct code refusing an incomplete construction, so
# the probe supplies null for what the engine names and asks again. The two
# types that needed it are pinned: a type that starts demanding
# caller-supplied state is a change to notice, not to absorb.
EXPECTED_SUPPLIED="supplied.qs.common.ScrollBar=flickable: null
supplied.qs.features.bar.modules.Tray.TrayMenuRow=entry: null"

# The counts, for a reader who wants the shape without counting lines.
# 230 declared entries over 46 qmldir files, one of which is excluded from the
# work list (boot/Boot.qml), so 229 cases are built. The 117 that are not built
# are the needs-environment and declared-but-uncreatable sets below.
# (+2 for the swap library: qs.common.CrossfadeIcon and qs.common.SlideSwap,
# both clean headless builds - plain items over Icons/Texts.)
EXPECTED_DECLARED_COUNT=230
# qs.common.AppIcons is a clean type: it resolves icon names through the
# static Quickshell.iconPath and BoundedCache, with no window and no
# environment behind it.
# qs.common.Chevron, qs.common.SkeletonPulse and qs.common.FullscreenProbe
# are clean for the same kind of reason: two plain Items/an animation and
# one singleton that only reads Hyprland.monitors, with no window behind any
# of them.
# qs.common.LiveMeter is clean for a third reason: a bare Rectangle with a
# Glide and a ColorAnim inside it, and a `peak` that defaults rather than
# being required so the type constructs without a call site.
# qs.common.IslandNav joins them for a fourth: a plain Item whose only
# dependencies are PanelFocus, Ui and a .pragma library, and every one of
# those constructs headlessly.
# qs.common.FlashReveal joins them for a fifth and simplest reason: an Item
# and a Timer, reading no singleton and no bar token, so the shared reveal
# window constructs without any environment behind it.
# qs.common.Vignette is in the same class: a plain Item over a Shape and a
# radial gradient, with no singleton and no window behind it.
EXPECTED_CLEAN_COUNT=112
EXPECTED_NEEDS_COUNT=95
EXPECTED_UNCREATABLE_COUNT=22

# --------------------------------------------------------------------------
# the generated case list
# --------------------------------------------------------------------------
#
# Each row names a case and the probe composes the document, because the two
# ways of writing a case are not the same question. A singleton is named
# rather than instantiated - QQmlEngine builds one the first time anything
# names it, and `Alias.Paths { }` is refused outright - and a plain type is
# instantiated under its own module alias, so a name two modules declare is
# built from the right one.
#
# the list itself imports nothing but QtQml and names no shell type, so it
# cannot fail to load. A case that reached this file as a type reference would
# let the one type that needs a PanelWindow take the other 227 with it.
WORKLIST="$_QP_CFG/ConstructionWorklist.qml"

{
  printf '// GENERATED by tests/shell/suites/qml/construction-test.sh - do not edit.\n'
  printf '// One row per qmldir entry: [module, name, kind, bucket, reason].\n'
  printf 'import QtQml\n\nQtObject {\n  readonly property var cases: [\n'
  while IFS=$'\t' read -r e_mod e_name e_kind e_rel e_dir _e_line; do
    if [[ "$e_mod$KEY_TAB$e_name" == "$BOOT_EXCLUDED" ]]; then
      continue
    fi
    root="$(awk -F'\t' -v m="$e_mod" -v n="$e_name" '$1 == m && $2 == n { print $3 }' "$ROOTS")"
    if [[ $e_kind == type ]] && is_cxx_root "$root"; then
      printf '    ["%s", "%s", "type", "declared-but-uncreatable", "root object %s is a Quickshell C++-registered type, uncreatable outside a live runtime"],\n' \
        "$e_mod" "$e_name" "$root"
      continue
    fi
    printf '    ["%s", "%s", "%s", "construct", ""],\n' "$e_mod" "$e_name" "$e_kind"
  done <"$ENTRIES"
  printf '    ""\n'
  printf '  ]\n}\n'
} >"$WORKLIST"

# One row per case, plus the bare "" that closes the array.
CASE_COUNT="$(grep -c '^    \["' "$WORKLIST")"

# --------------------------------------------------------------------------
# 1. the work list
# --------------------------------------------------------------------------

t_section "the work list comes from the qmldir files, not from a hand-written list"

t_eq "the number of qmldir files" "46" "$QMLDIR_COUNT"

# The declared surface itself, held still. Every count below is measured
# against a list that moved, so without this the suite would stay green while
# the thing it measures drifts: a qmldir entry added is a type nothing is
# building, and a type removed is a bucket member that no longer exists.
t_count "the number of declared entries" "$EXPECTED_DECLARED_COUNT" "$ENTRY_COUNT"

# The README's "46 qmldir files declare module boundaries (43 of them under
# features/)", restated here so the suite says what it counted even when it is
# only listing.
t_note "the module surface: $ENTRY_COUNT declared entries over $QMLDIR_COUNT modules - \
$(awk -F'\t' '$3 == "singleton"' "$ENTRIES" | wc -l | tr -d ' ') singletons and \
$(awk -F'\t' '$3 == "type"' "$ENTRIES" | wc -l | tr -d ' ') plain types"

t_file "the generated case list exists" "$WORKLIST"
t_count "one case per declared entry, minus the one excluded entry" \
  "$(( ENTRY_COUNT - 1 ))" "$CASE_COUNT"

# The point of the shape: the generated list imports no shell module and
# references no shell type, so nothing in it can fail to load. A case that
# reached this file as a type reference instead of as a string would let the
# one type that needs a PanelWindow take the other 227 down with it.
t_eq "the generated list imports no module of its own" "" \
  "$(grep '^import' "$WORKLIST" | grep -v '^import QtQml$' || true)"

# One safety exclusion, named. The task of this suite is to build declared
# types; boot/Boot.qml is the one that builds the shell, so it is not a case
# and its absence is recorded rather than left implicit.
t_note "excluded from the work list: qs.boot.Boot - boot/Boot.qml is the composition root, \
and its Component.onCompleted drains the boot catalog, so constructing it would start a second shell \
inside the test process. qs.boot.BootRegistry is still built, so the module is covered."

# The set of declared types whose own root object is a Quickshell C++ type.
# These cannot be built here, and the suite's answer has to be that set exactly
# rather than whatever the offscreen platform happens to refuse today: a type
# that starts needing a new thing has to be visible.
UNCREATABLE="$WORK/uncreatable.txt"
UNCREATABLE_REASONS="$WORK/uncreatable-reasons.tsv"
: >"$UNCREATABLE"
: >"$UNCREATABLE_REASONS"
while IFS=$'\t' read -r e_mod e_name e_root _e_rel; do
  is_cxx_root "$e_root" || continue
  printf '%s.%s\n' "$e_mod" "$e_name" >>"$UNCREATABLE"
  printf '%s\t%s\t%s\n' "$e_mod" "$e_name" "$e_root" >>"$UNCREATABLE_REASONS"
done <"$ROOTS"
LC_ALL=C sort -o "$UNCREATABLE" "$UNCREATABLE"

# --------------------------------------------------------------------------
# 2. the run
# --------------------------------------------------------------------------

t_section "every remaining declared type is built, in its own document, against a private filesystem"

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/construction.qml" 45; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

# qp_get is the harness's; qp_out is too, but only on a run that failed. This
# dumps the whole probe transcript on a run that passed, which is the only way
# to see a per-type diagnostic for a type that moved bucket.
if [[ -n ${VB_CT_DEBUG:-} ]]; then
  printf '###RAWOUT-BEGIN\n%s\n###RAWOUT-END\n' "$(qp_out)"
fi

t_not_empty "the probe reported how many cases it built" "$(qp_get probe.cases)"
t_count "the generated list holds one case per declared entry plus its terminator" \
  "$(( CASE_COUNT + 1 ))" "$(qp_get probe.listed)"
t_count "it built one case per generated row" "$CASE_COUNT" "$(qp_get probe.cases)"
t_eq "every case reached a bucket" "true" "$(qp_get probe.complete)"
t_eq "the probe itself did not error" "" "$(qp_get probe.error)"
t_eq "no case escaped its own try/catch" "" "$(qp_get probe.case.error)"

# The isolation is only worth having if the probe process actually saw it, so it
# is read back out of the probe rather than assumed from the exports.
t_not_empty "the probe reported the environment it built in" "$(qp_get probe.isolation)"
OFF_ROOTS=""
for var in XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME VIBRANIUM_RUNTIME; do
  value="$(sed -n "s/.*$var=\([^ ]*\).*/\1/p" <<<"$(qp_get probe.isolation)")"
  [[ $value == "$ISOLATION"/* ]] || OFF_ROOTS+="$var=$value "
done
t_eq "every root the probe built against is the suite's own, not the session's" "" "$OFF_ROOTS"

# A type that declares `required property` cannot be built bare, and the
# refusal is correct code rather than a defect: the probe supplies what the
# engine asks for and asks again. Which types needed that is pinned, because a
# type that starts demanding caller-supplied state is a change to notice.
SUPPLIED="$WORK/supplied.txt"
sed -n 's/.*##KV## \(supplied\..*\)$/\1/p' "$_QP_OUT" >"$SUPPLIED"
t_eq "the types that needed a required property supplied" \
  "$EXPECTED_SUPPLIED" "$(cat "$SUPPLIED")"

# --------------------------------------------------------------------------
# 3. the buckets
# --------------------------------------------------------------------------

t_section "every declared type is accounted for in exactly one bucket"

CLEAN="$WORK/clean.txt"
NEEDS="$WORK/needs-environment.txt"
BROKEN="$WORK/broken.txt"
REASONS="$WORK/reasons.tsv"
: >"$CLEAN"
: >"$NEEDS"
: >"$BROKEN"
: >"$REASONS"

while IFS=$'\t' read -r e_mod e_name _e_kind _e_rel _e_dir _e_line; do
  [[ "$e_mod$KEY_TAB$e_name" == "$BOOT_EXCLUDED" ]] && continue
  key="type.$e_mod.$e_name"
  bucket="$(qp_get "$key")"
  case "$bucket" in
    clean)                 printf '%s\t%s\n' "$e_mod" "$e_name" >>"$CLEAN" ;;
    needs-environment)     printf '%s.%s\n' "$e_mod" "$e_name" >>"$NEEDS"
                           printf '%s\t%s\t%s\n' "$e_mod" "$e_name" "$(qp_get "err.$e_mod.$e_name")" >>"$REASONS" ;;
    declared-but-uncreatable) ;;
    *)                     printf '%s\t%s\t%s\n' "$e_mod" "$e_name" "$bucket" >>"$BROKEN" ;;
  esac
done <"$ENTRIES"

LC_ALL=C sort -o "$CLEAN" "$CLEAN"
LC_ALL=C sort -o "$NEEDS" "$NEEDS"

# (a) the total is the declared entries. Each entry contributes to exactly one
# bucket, so the three lists plus the uncreatable set must add up.
BUCKET_TOTAL="$(( $(wc -l <"$CLEAN") + $(wc -l <"$NEEDS") + $(wc -l <"$UNCREATABLE") + $(wc -l <"$BROKEN") ))"
t_count "the buckets cover every declared entry but the excluded one" \
  "$(( ENTRY_COUNT - 1 ))" "$BUCKET_TOTAL"

# A type that reported no bucket at all is worse than one in the wrong bucket:
# it is a type nothing looked at.
UNREPORTED=""
while IFS=$'\t' read -r e_mod e_name _e_kind _e_rel _e_dir _e_line; do
  [[ "$e_mod$KEY_TAB$e_name" == "$BOOT_EXCLUDED" ]] && continue
  qp_probe_ran "type.$e_mod.$e_name" || UNREPORTED+="$e_mod.$e_name "
done <"$ENTRIES"
t_eq "every built type reported a bucket" "" "$UNREPORTED"

t_note "buckets: $(wc -l <"$CLEAN" | tr -d ' ') clean, $(wc -l <"$NEEDS" | tr -d ' ') needs-environment, \
$(wc -l <"$UNCREATABLE" | tr -d ' ') declared-but-uncreatable, $(wc -l <"$BROKEN" | tr -d ' ') broken"

# The headline observation, because a reader who sees 116 of the 228 types "not
# built" deserves the one sentence that explains all of it: under
# QT_QPA_PLATFORM=offscreen Quickshell loads no PanelWindow backend, so no type
# that reaches a window can be constructed at all. The widest door is the
# Screenshots singleton, which builds a PanelWindow while it is being
# constructed, and everything that touches it - which is all of qs.services -
# goes with it. One environmental fact, not 116 problems.
t_note "every needs-environment type failed for one reason: the offscreen platform has no \
PanelWindow backend, so a type that reaches a window cannot be built. That includes types that reach \
one transitively, through the Screenshots singleton that builds a PanelWindow at construction."

# (b) broken is empty. The detail names every member, so a failure reports
# which type and which bucket the probe actually gave it, not a count.
t_eq "no declared type fails to construct" "" "$(cat "$BROKEN")"

t_section "declared-but-uncreatable is exactly the C++-rooted set"

t_eq "the set of types whose root object is Quickshell C++-registered" \
  "$EXPECTED_UNCREATABLE" "$(cat "$UNCREATABLE")"
t_count "how many declared types that is" "$EXPECTED_UNCREATABLE_COUNT" \
  "$(wc -l <"$UNCREATABLE" | tr -d ' ')"

# The reason is not decoration: it names the C++ type the entry's own file is
# built on, so a type that moved to a different root says so.
t_note "the C++ roots behind them: $(cut -f3 "$UNCREATABLE_REASONS" | LC_ALL=C sort | uniq -c | tr '\n' ' ')"
while IFS=$'\t' read -r u_mod u_name _u_root; do
  t_contains "$u_mod.$u_name is built on a Quickshell C++ root" "Quickshell C++-registered" \
    "$(qp_get "err.$u_mod.$u_name")"
done <"$UNCREATABLE_REASONS"

# The set above is the driver's; this is the probe's. They are derived from
# opposite ends - the installed type descriptions against the root object on
# one side, the engine's own refusal on the other - so agreement is a fact
# rather than a tautology, and disagreement names the type.
MISMATCHED=""
while IFS=$'\t' read -r u_mod u_name _u_root; do
  if [[ "$(qp_get "type.$u_mod.$u_name")" != declared-but-uncreatable ]]; then
    MISMATCHED+="$u_mod.$u_name "
  fi
done <"$UNCREATABLE_REASONS"
t_eq "the probe agreed about every one of them" "" "$MISMATCHED"

t_section "needs-environment types are pinned, and each says why"

t_eq "the set of types that build only with a real environment" \
  "$EXPECTED_NEEDS_ENVIRONMENT" "$(cat "$NEEDS")"
t_count "how many declared types that is" "$EXPECTED_NEEDS_COUNT" \
  "$(wc -l <"$NEEDS" | tr -d ' ')"

# (d) no needs-environment type is allowed to be unexplained. The reason has to
# be the phrase the type itself reported, and it has to be one the probe's table
# already names. A reason that is empty, or that is not in the table, means a
# type started needing something nobody decided was acceptable - and it stays a
# broken type until that decision is made here.
t_eq "the reason strings are exactly the ones the probe knows" \
  "$EXPECTED_NEEDS_REASONS" "$(cut -f3 "$REASONS" | LC_ALL=C sort -u)"
EMPTY_REASONS="$(awk -F'\t' '$3 == "" { print $1 "." $2 }' "$REASONS" | tr '\n' ' ')"
t_eq "no needs-environment type is unexplained" "" "$EMPTY_REASONS"

# One assertion per member, so a type that starts needing a new environment is
# reported by name rather than as a diff between two 97-line lists.
while IFS=$'\t' read -r n_mod n_name _n_reason; do
  t_eq "$n_mod.$n_name names the environment it needs" \
    "No PanelWindow backend loaded" "$(qp_get "err.$n_mod.$n_name")"
done <"$REASONS"

t_section "the clean set"

t_count "how many declared types build headlessly" "$EXPECTED_CLEAN_COUNT" \
  "$(wc -l <"$CLEAN" | tr -d ' ')"
# A clean type prints no err. key, so one that does is a type the probe
# half-completed rather than one that built.
CLEAN_WITH_ERROR=""
while IFS=$'\t' read -r c_mod c_name; do
  if qp_probe_ran "err.$c_mod.$c_name"; then
    CLEAN_WITH_ERROR+="$c_mod.$c_name "
  fi
done <"$CLEAN"
t_eq "a clean type reports no reason" "" "$CLEAN_WITH_ERROR"

t_summary
